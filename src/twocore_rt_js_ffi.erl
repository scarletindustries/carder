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
    new_object/0, wrapper_new/2, gen_make/1, gen_next/2, iter_array/1, get_prop/2, set_prop/3, define_data/3, define_accessor/4,
    static_get/2, static_get_chain/2, static_set/3, has_prop/2, delete_prop/2,
    new_array/1, array_construct/1, array_push/2, array_pop/1, is_array/1, array_spread_into/2,
    array_from/1, array_from_map/2, array_flat/2, array_fill/4, array_copy_within/4, array_splice/2, array_at/2,
    apply_fn/2, fit_list/2, array_to_list/1,
    str_pad_start/3, str_pad_end/3, string_from_char_code/1,
    string_from_code_point/1, string_raw/2, date_now/0,
    date_new/1, date_utc/1, date_parse/1, date_call/3,
    array_flat_map/2, array_find_last/2, array_find_last_index/2,
    array_last_index_of/3, num_to_fixed/2, num_to_exponential/2, num_to_precision/2,
    to_string_dispatch/1, num_to_string_radix/2,
    new_regex/2, regex_test/2, regex_source/1, regex_flags/1, str_match/2,
    new_map/1, new_set/1, js_m_set/2, js_m_get/2, js_m_add/2, js_m_has/2,
    js_m_delete/2, js_m_clear/2, js_m_foreach/2,
    array_map/2, array_filter/2, array_foreach/2, array_reduce/3,
    array_reduce1/2, array_reduce_right/3, array_reduce_right1/2,
    array_some/2, array_every/2, array_find/2, array_includes/3,
    array_find_index/2, array_index_of/3, array_join/2,
    array_slice/3, array_concat/2, array_reverse/1, array_shift/1,
    array_unshift/2, array_sort/2,
    array_to_reversed/1, array_to_sorted/2, array_with/3, array_to_spliced/2,
    str_char_at/2, str_char_code_at/2, str_code_point_at/2, str_normalize/2,
    str_upper/1, str_lower/1,
    str_substring/3, str_split/2, str_trim/1, str_trim_start/1,
    str_trim_end/1, str_repeat/2, str_starts_with/3, str_ends_with/3,
    str_replace/3, str_replace_all/3,
    parse_int/2, parse_float/1, is_nan/1, is_finite/1, is_nullish/1,
    number_is_nan/1, number_is_finite/1, number_is_integer/1,
    number_is_safe_integer/1,
    object_keys/1, object_values/1, object_entries/1, object_assign_into/2,
    object_rest/2, object_freeze/1, object_is_frozen/1,
    object_from_entries/1,
    json_stringify/3, json_parse/1,
    encode_uri_component/1, encode_uri/1,
    decode_uri_component/1, decode_uri/1,
    empty_list/0, console_log/1, not_callable/1
]).

%% The pdict key of a cell (namespaced so it can never collide with
%% `rt_state`'s instance key or a generated module's own keys).
-define(CELL_KEY(Ref), {twocore_rt_js_cell, Ref}).

%% The exact set of code points ToNumber(String) strips from both ends: the ES
%% WhiteSpace set (TAB, VT, FF, SP, NBSP, ZWNBSP, and Space_Separator U+1680 /
%% U+2000–U+200A / U+202F / U+205F / U+3000) plus LineTerminator (LF, CR, LS, PS).
-define(JS_WS, [
    16#09, 16#0A, 16#0B, 16#0C, 16#0D, 16#20, 16#A0, 16#1680,
    16#2000, 16#2001, 16#2002, 16#2003, 16#2004, 16#2005, 16#2006, 16#2007,
    16#2008, 16#2009, 16#200A, 16#2028, 16#2029, 16#202F, 16#205F, 16#3000,
    16#FEFF
]).

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
%% Math.clz32 coerces with ToUint32 (not the sentinel float path): NaN/Infinity
%% → 0 → 32 leading zeros. clz32(0) = 32, else 32 minus the number of binary digits.
math_unary(clz32, X) ->
    U = js_to_uint32(X),
    case U of
        0 -> 32;
        _ -> 32 - length(integer_to_list(U, 2))
    end;
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
munary_inf(expm1, 1) -> inf;
munary_inf(expm1, -1) -> -1;
munary_inf(log, 1) -> inf;
munary_inf(log2, 1) -> inf;
munary_inf(log10, 1) -> inf;
munary_inf(log1p, 1) -> inf;
munary_inf(fround, S) -> inf_of(S);
%% hyperbolics: sinh(±∞)=±∞, cosh(±∞)=+∞, tanh(±∞)=±1.
munary_inf(sinh, S) -> inf_of(S);
munary_inf(cosh, _) -> inf;
munary_inf(tanh, S) -> S;
%% inverse hyperbolics: asinh(±∞)=±∞, acosh(+∞)=+∞ (−∞ → NaN), atanh(±∞)=NaN.
munary_inf(asinh, S) -> inf_of(S);
munary_inf(acosh, 1) -> inf;
%% atan approaches a right angle at the infinities: atan(±∞) = ±π/2. (sin/cos/
%% tan/asin/acos are all NaN there and fall through to the catch-all below.)
munary_inf(atan, S) -> S * math:pi() / 2;
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
%% ES2015 hyperbolics and their inverses (Erlang's math module provides all six).
munary_finite(sinh, N) -> guard_inf(fun() -> math:sinh(as_float(N)) end);
munary_finite(cosh, N) -> guard_inf(fun() -> math:cosh(as_float(N)) end);
munary_finite(tanh, N) -> math:tanh(as_float(N));
munary_finite(asinh, N) -> math:asinh(as_float(N));
%% acosh domain is [1, ∞); atanh domain is (-1, 1) with ±1 → ±∞.
munary_finite(acosh, N) when N < 1 -> nan;
munary_finite(acosh, N) -> math:acosh(as_float(N));
munary_finite(atanh, N) when N < -1; N > 1 -> nan;
munary_finite(atanh, N) when N == 1 -> inf;
munary_finite(atanh, N) when N == -1 -> neg_inf;
munary_finite(atanh, N) -> math:atanh(as_float(N));
%% expm1(x) = eˣ − 1 and log1p(x) = ln(1 + x), the accurate-near-zero variants.
munary_finite(expm1, N) -> guard_inf(fun() -> math:exp(as_float(N)) - 1 end);
munary_finite(log1p, N) when N < -1 -> nan;
munary_finite(log1p, N) when N == -1 -> neg_inf;
munary_finite(log1p, N) -> math:log(1 + as_float(N));
%% Math.fround rounds to the nearest single-precision float (round-trip via a
%% 32-bit binary); a magnitude beyond float32's range overflows to ±Infinity.
munary_finite(fround, N) ->
    F = as_float(N),
    try
        <<R:32/float>> = <<F:32/float>>,
        R
    catch
        error:badarg ->
            case F < 0 of
                true -> neg_inf;
                false -> inf
            end
    end;
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

%% Binary Math functions: Math.pow(a,b), Math.atan2(y,x), Math.imul(a,b).
math_binary(pow, A, B) -> pow(A, B);
math_binary(atan2, A, B) ->
    out(matan2(coerce_num(A), coerce_num(B)));
%% Math.imul: C-like 32-bit integer multiply — both operands ToUint32, multiply,
%% then reinterpret the low 32 bits as a signed int32 (wrap_int32 masks).
math_binary(imul, A, B) ->
    wrap_int32(js_to_uint32(A) * js_to_uint32(B)).

%% Math.atan2(y, x) — the polar angle of the point (x, y). The infinite cases
%% have EXACT results per the ECMAScript spec table (approximating ±∞ with the
%% largest double is wrong: e.g. atan2(finite, +∞) must be an exact ±0, not the
%% tiny denormal a huge-but-finite x would yield).
matan2(nan, _) -> nan;
matan2(_, nan) -> nan;
%% y = +∞: +π/4 when x = +∞, +3π/4 when x = −∞, else +π/2 (x finite).
matan2(inf, inf) -> math:pi() / 4;
matan2(inf, neg_inf) -> 3 * math:pi() / 4;
matan2(inf, _) -> math:pi() / 2;
%% y = −∞: the mirror image of the +∞ block.
matan2(neg_inf, inf) -> -math:pi() / 4;
matan2(neg_inf, neg_inf) -> -3 * math:pi() / 4;
matan2(neg_inf, _) -> -math:pi() / 2;
%% finite y, x = +∞: a signed zero taking y's sign (y>0 → +0, y<0 → −0).
matan2(Y, inf) -> signed_zero(zero_aware_sign(Y));
%% finite y, x = −∞: ±π taking y's sign.
matan2(Y, neg_inf) ->
    case zero_aware_sign(Y) of
        -1 -> -math:pi();
        _ -> math:pi()
    end;
%% both finite (including signed zeros): the library atan2 is already correct.
matan2(Y, X) -> math:atan2(as_float(Y), as_float(X)).

%% Variadic Math.min / Math.max / Math.hypot over the emitter's cons list of args.
math_reduce(Method, Args) ->
    out(mreduce(Method, [coerce_num(A) || A <- Args])).

mreduce(min, []) -> inf;
mreduce(max, []) -> neg_inf;
mreduce(hypot, []) -> 0;
%% Math.hypot: per spec, if ANY argument is ±Infinity the result is +Infinity
%% (even when another argument is NaN); otherwise a NaN argument yields NaN;
%% otherwise sqrt of the sum of squares. (The old code multiplied the NaN atom and
%% crashed with badarith on hypot(Infinity, NaN) / hypot(NaN, x).)
mreduce(hypot, Nums) ->
    case lists:member(inf, Nums) orelse lists:member(neg_inf, Nums) of
        true ->
            inf;
        false ->
            case lists:member(nan, Nums) of
                true ->
                    nan;
                false ->
                    Sum = lists:foldl(
                        fun(N, A) -> F = as_float(N), A + F * F end, 0.0, Nums),
                    math:sqrt(Sum)
            end
    end;
mreduce(Method, Nums) ->
    case lists:member(nan, Nums) of
        true -> nan;
        _ -> mreduce_go(Method, Nums)
    end.

mreduce_go(min, Nums) -> lists:foldl(fun mmin/2, hd(Nums), tl(Nums));
mreduce_go(max, Nums) -> lists:foldl(fun mmax/2, hd(Nums), tl(Nums)).

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
        {js_date, Ms} -> date_to_string(Ms);
        %% a primitive wrapper stringifies as its boxed primitive (ToPrimitive → ToString).
        {js_wrapper, _Kind, Prim} -> to_string(Prim);
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
    T = unicode:characters_to_binary(string:trim(Bin, both, ?JS_WS)),
    case T of
        <<>> -> 0;
        <<"Infinity">> -> inf;
        <<"+Infinity">> -> inf;
        <<"-Infinity">> -> neg_inf;
        %% Non-decimal integer literals (NO sign is permitted after the prefix).
        <<"0x", H/binary>> -> radix_int(H, 16);
        <<"0X", H/binary>> -> radix_int(H, 16);
        <<"0o", O/binary>> -> radix_int(O, 8);
        <<"0O", O/binary>> -> radix_int(O, 8);
        <<"0b", B/binary>> -> radix_int(B, 2);
        <<"0B", B/binary>> -> radix_int(B, 2);
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

%% Parse the digits after a 0x/0o/0b prefix in the given base; empty digits or a
%% sign (both illegal after the prefix) or any out-of-base digit yields NaN.
radix_int(<<>>, _Base) -> nan;
radix_int(<<S, _/binary>>, _Base) when S =:= $+; S =:= $- -> nan;
radix_int(Digits, Base) ->
    try
        binary_to_integer(Digits, Base)
    catch
        error:badarg -> nan
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

%% `new Number(x)` / `new String(x)` / `new Boolean(x)` — a primitive WRAPPER object:
%% a cell holding `{js_wrapper, Kind, Prim}` where `Kind` is the atom `number`/`string`/
%% `boolean` and `Prim` is the coerced primitive (ToNumber / ToString / ToBoolean of `X`).
%% Being a cell (reference) it is `typeof` "object"; `valueOf` unwraps to `Prim` and
%% `toString`/string-coercion unwraps to `to_string(Prim)` (see `date_call`, `get_prop`
%% and `to_string`). A `string` wrapper additionally exposes `.length` and index access
%% through `get_prop` (delegating to the string primitive).
wrapper_new(number, X) -> cell_new({js_wrapper, number, to_number(X)});
wrapper_new(string, X) -> cell_new({js_wrapper, string, to_string(X)});
wrapper_new(boolean, X) -> cell_new({js_wrapper, boolean, truthy(X) =:= 1}).

%% A generator object — a cell holding the compiled step closure. The frontend
%% transforms `function* g(){…}` into a state machine (a closure over a persistent
%% context) and hands the step function here. `.next(v)` drives one step. Once the
%% state machine reaches its DONE state it permanently returns {value:undefined,
%% done:true}, so no extra done-tracking is needed here.
gen_make(StepFn) ->
    cell_new({js_gen, StepFn}).

%% The source of a `for-of` as an array: an array passes through, a string is
%% left as-is (for-of indexes it directly), and a GENERATOR is drained to an array
%% by driving `.next()` to completion (so a finite generator iterates; an infinite
%% one would loop — use manual `.next()` there). Anything else is empty.
iter_array(X) when is_reference(X) ->
    case erlang:get(?CELL_KEY(X)) of
        {js_gen, _} -> new_array(drain_gen(X, []));
        {js_array, _, _} -> X;
        _ -> new_array([])
    end;
iter_array(X) when is_binary(X) ->
    X;
iter_array(_) ->
    new_array([]).

drain_gen(Gen, Acc) ->
    R = gen_next(Gen, []),
    case get_prop(R, <<"done">>) of
        true -> lists:reverse(Acc);
        _ -> drain_gen(Gen, [get_prop(R, <<"value">>) | Acc])
    end.

%% `gen.next(v)` — advance the generator (StepFn returns the `{value, done}`
%% object). On a non-generator receiver, delegate to a user `next` method (so an
%% ordinary iterator/cursor object with its own `next` still works).
gen_next(Recv, Args) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_gen, StepFn} -> call_cb(StepFn, [arg(Args, 0)]);
        _ -> delegate(Recv, <<"next">>, Args)
    end;
gen_next(Recv, Args) ->
    delegate(Recv, <<"next">>, Args).

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
        %% a generator object: arbitrary property reads are `undefined` (`.next`
        %% is dispatched by the compiler to gen_next, not via get_prop).
        {js_gen, _} ->
            undefined;
        %% a primitive wrapper: a String wrapper exposes the string primitive's
        %% `.length` / index reads; Number/Boolean wrappers have no own data props.
        {js_wrapper, string, Str} ->
            string_prop(Str, Key);
        {js_wrapper, _Kind, _Prim} ->
            undefined;
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

%% recv[key] = v — stores and returns v (the value of a JS assignment). A FROZEN
%% object/array (Object.freeze) silently ignores the write in non-strict mode.
set_prop(Recv, Key, V) when is_reference(Recv) ->
    case erlang:get({js_frozen, Recv}) of
        true ->
            V;
        _ ->
            set_prop_live(Recv, Key, V)
    end;
set_prop(Recv, _Key, _V) ->
    type_error(Recv).

set_prop_live(Recv, Key, V) ->
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
    end.

%% Object.freeze(o): mark o immutable — subsequent own-property writes/deletes are
%% no-ops (non-strict mode) — and return o. Frozen-ness is tracked in a SEPARATE
%% process-dictionary entry keyed by the cell ref, so it never appears among the
%% object's keys. A non-object primitive is returned unchanged (already immutable).
object_freeze(O) when is_reference(O) ->
    erlang:put({js_frozen, O}, true),
    O;
object_freeze(O) ->
    O.

%% Object.isFrozen(o) -> JS boolean. A non-object primitive is frozen (true) per
%% spec.
object_is_frozen(O) when is_reference(O) ->
    erlang:get({js_frozen, O}) =:= true;
object_is_frozen(_) ->
    true.

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
    case erlang:get({js_frozen, Recv}) of
        true ->
            %% frozen: delete is a no-op in non-strict mode, and reports false.
            false;
        _ ->
            delete_prop_live(Recv, Key)
    end;
delete_prop(_Recv, _Key) ->
    true.

delete_prop_live(Recv, Key) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_array, Len, Map} ->
            erlang:put(?CELL_KEY(Recv), {js_array, Len, maps:remove(array_key(Key), Map)}),
            true;
        M when is_map(M) ->
            erlang:put(?CELL_KEY(Recv), maps:remove(prop_key(Key), M)),
            true;
        _ ->
            true
    end.

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

%% `Array(...)` / `new Array(...)`: a SINGLE numeric argument is the new array's
%% LENGTH — a sparse array of that many holes (reads return undefined). Any other
%% argument list becomes the elements. A single Number that is not a valid array
%% length (negative, fractional, or ≥ 2^32, incl. NaN/±Infinity) is a RangeError.
array_construct([N]) when is_number(N); N =:= inf; N =:= neg_inf; N =:= nan ->
    case is_array_length(N) of
        true -> cell_new({js_array, trunc(as_float(N)), #{}});
        false -> erlang:error({js_error, range_error, <<"Invalid array length">>})
    end;
array_construct(Args) when is_list(Args) ->
    new_array(Args);
array_construct(V) ->
    type_error(V).

is_array_length(N) when is_integer(N) -> N >= 0 andalso N < 16#100000000;
is_array_length(N) when is_float(N) ->
    N >= 0 andalso N < 16#100000000 andalso trunc(N) == N;
is_array_length(_) -> false.

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

%% Every array IS an Array instance, so `x instanceof Array` (compiled to a
%% has_prop for the `@@is_Array` brand) is true for any array cell — arrays carry
%% no explicit brand key, so recognise it here.
array_has(_Map, <<"@@is_Array">>) -> 1;
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

%% Array.from(x) / Array.from(x, mapFn) — a NEW array built from an array (copy),
%% a string (its code points), or an array-like object (any object carrying a
%% `length` property plus 0-based index properties). Elements are read one at a
%% time in index order via a fresh Get, so a `mapFn` that mutates the source array
%% observes its own writes (the array-iterator / per-index Get of §23.1.2.1); the
%% element count is fixed once at entry — an array's live length, a string's
%% code-point count, or ToLength(Get(obj,"length")) for an array-like. Holes and
%% absent indices read as `undefined`. Any other value yields an empty array.
array_from(X) ->
    new_array(array_from_elems(X, undefined)).

%% Array.from(x, mapFn) — as array_from, with mapFn(element, index) applied to each
%% element as it is read (§23.1.2.1 step 7); a mapFn of `undefined` means no mapping.
array_from_map(X, Fn) ->
    new_array(array_from_elems(X, Fn)).

array_from_elems(X, Fn) when is_binary(X) ->
    from_map_list([from_cps([C]) || C <- cps(X)], Fn, 0);
array_from_elems(X, Fn) when is_reference(X) ->
    from_map_index(X, Fn, 0, arr_from_length(X));
array_from_elems(_X, _Fn) ->
    [].

%% The number of elements Array.from reads from a cell: an array's live length,
%% ToLength(Get(obj,"length")) for an array-like object, or 0 for any other cell
%% (Map/Set/RegExp/Date/generator — not iterated here, a v1 gap).
arr_from_length(X) ->
    case erlang:get(?CELL_KEY(X)) of
        {js_array, Len, _} -> Len;
        M when is_map(M) -> to_length(resolve_get(maps:get(<<"length">>, M, undefined)));
        _ -> 0
    end.

%% Build [f(x_K,K), …, f(x_{N-1},N-1)] reading each x_k FRESH from cell X (so a
%% mapping callback sees writes it makes to later indices), f being `Fn` or the
%% identity when Fn is `undefined`.
from_map_index(_X, _Fn, K, N) when K >= N -> [];
from_map_index(X, Fn, K, N) ->
    [from_apply(Fn, arr_from_get(X, K), K) | from_map_index(X, Fn, K + 1, N)].

%% As from_map_index but over an already-materialized element list (the string case).
from_map_list([], _Fn, _I) -> [];
from_map_list([E | Es], Fn, I) ->
    [from_apply(Fn, E, I) | from_map_list(Es, Fn, I + 1)].

from_apply(undefined, E, _I) -> E;
from_apply(Fn, E, I) -> call_cb(Fn, [E, I]).

%% Read index K (0-based) fresh from an array or array-like object cell; a hole /
%% absent index reads as `undefined`.
arr_from_get(X, K) ->
    case erlang:get(?CELL_KEY(X)) of
        {js_array, _Len, Map} -> maps:get(K, Map, undefined);
        M when is_map(M) -> resolve_get(maps:get(to_string(K), M, undefined));
        _ -> undefined
    end.

%% ToLength(v) (§7.1.20): ToIntegerOrInfinity clamped to the array-index range
%% [0, 2^53-1]. NaN / -Infinity → 0; +Infinity → 2^53-1.
to_length(V) ->
    case coerce_num(V) of
        nan -> 0;
        neg_inf -> 0;
        inf -> 16#1FFFFFFFFFFFFF;
        N -> min(max(trunc(as_float(N)), 0), 16#1FFFFFFFFFFFFF)
    end.

%% ToIntegerOrInfinity(v) (§7.1.5): NaN → 0, ±Infinity pass through as inf/neg_inf,
%% otherwise truncate toward zero.
to_int_or_inf(V) ->
    case coerce_num(V) of
        nan -> 0;
        inf -> inf;
        neg_inf -> neg_inf;
        N -> trunc(as_float(N))
    end.

%% arr.flat() — flatten one level (array elements are spread in).
%% arr.flat(depth) — flatten nested arrays up to `depth` levels. Depth defaults to
%% 1; a provided value is ToIntegerOrInfinity (so flat(Infinity) fully flattens,
%% flat(0)/flat(NaN) copies one level unchanged).
array_flat(Recv, Depth) ->
    D =
        case Depth of
            undefined ->
                1;
            _ ->
                case coerce_num(Depth) of
                    nan -> 0;
                    inf -> inf;
                    neg_inf -> 0;
                    N -> max(0, trunc(as_float(N)))
                end
        end,
    {Len, Map} = arr_content(Recv),
    new_array(flat_depth(arr_list(Len, Map), D)).

flat_depth(List, 0) -> List;
flat_depth(List, D) -> lists:flatmap(fun(E) -> flat_elem(E, D) end, List).

flat_elem(E, D) ->
    case is_array(E) of
        1 ->
            {L, M} = arr_content(E),
            flat_depth(arr_list(L, M), dec_depth(D));
        0 ->
            [E]
    end.

dec_depth(inf) -> inf;
dec_depth(D) -> D - 1.

%% Flatten one level: an array contributes its elements, anything else itself.
%% (Used by flatMap, which flattens the mapped results by exactly one level.)
flat_one(E) ->
    case is_array(E) of
        1 ->
            {L, M} = arr_content(E),
            arr_list(L, M);
        0 ->
            [E]
    end.
%% arr.fill(v) — set every element to v (in place); returns the array.
%% arr.fill(value, start, end) — fill indices [start, end) with `value` and return
%% the array. start/end are ToIntegerOrInfinity, clamped to [0, len] with negatives
%% counting from the end; an omitted start is 0 and an omitted end is len.
array_fill(Recv, V, Start, End) ->
    {Len, Map} = arr_content(Recv),
    S = fill_clamp(Start, Len, 0),
    E = fill_clamp(End, Len, Len),
    erlang:put(?CELL_KEY(Recv), {js_array, Len, fill_range(Map, S, E, V)}),
    Recv.

fill_clamp(undefined, _Len, Default) ->
    Default;
fill_clamp(I, Len, _Default) ->
    case coerce_num(I) of
        nan ->
            0;
        inf ->
            Len;
        neg_inf ->
            0;
        Num ->
            N = trunc(as_float(Num)),
            case N < 0 of
                true -> max(Len + N, 0);
                false -> min(N, Len)
            end
    end.

fill_range(Map, S, E, _V) when S >= E -> Map;
fill_range(Map, S, E, V) -> fill_range(maps:put(S, V, Map), S + 1, E, V).

%% arr.copyWithin(target, start, end) — copy the elements in [start, end) to the
%% position `target`, in place, returning the array. Indices are ToIntegerOrInfinity
%% clamped to [0, len] with negatives counting from the end. A source hole clears
%% the target (delete), so holes propagate rather than becoming `undefined`.
array_copy_within(Recv, Target, Start, End) ->
    {Len, Map} = arr_content(Recv),
    T = fill_clamp(Target, Len, 0),
    S = fill_clamp(Start, Len, 0),
    E = fill_clamp(End, Len, Len),
    Count = min(E - S, Len - T),
    case Count =< 0 of
        true ->
            Recv;
        false ->
            Src = [{maps:is_key(S + I, Map), maps:get(S + I, Map, undefined)}
                   || I <- lists:seq(0, Count - 1)],
            NewMap = lists:foldl(
                fun({{HasKey, V}, I}, M) ->
                    case HasKey of
                        true -> maps:put(T + I, V, M);
                        false -> maps:remove(T + I, M)
                    end
                end,
                Map,
                lists:zip(Src, lists:seq(0, Count - 1))
            ),
            erlang:put(?CELL_KEY(Recv), {js_array, Len, NewMap}),
            Recv
    end.

%% arr.splice(start, deleteCount, ...items) — remove `deleteCount` elements at
%% `start`, insert `items` in their place (in place), and return the removed
%% elements as a new array. start is ToIntegerOrInfinity clamped to [0, len]
%% (negatives from the end); with only `start` given, everything from `start` is
%% removed; deleteCount is clamped to [0, len - start].
array_splice(Recv, Args) ->
    {Len, Map} = arr_content(Recv),
    List = arr_list(Len, Map),
    {Start, DelCount, Items} = splice_args(Args, Len),
    Removed = lists:sublist(List, Start + 1, DelCount),
    Prefix = lists:sublist(List, Start),
    Suffix = lists:nthtail(min(Start + DelCount, Len), List),
    arr_store(Recv, Prefix ++ Items ++ Suffix),
    new_array(Removed).

splice_args([], _Len) ->
    {0, 0, []};
splice_args([StartArg], Len) ->
    S = fill_clamp(StartArg, Len, 0),
    {S, Len - S, []};
splice_args([StartArg, DelArg | Items], Len) ->
    S = fill_clamp(StartArg, Len, 0),
    D =
        case coerce_num(DelArg) of
            nan -> 0;
            neg_inf -> 0;
            inf -> Len - S;
            N -> max(0, min(trunc(as_float(N)), Len - S))
        end,
    {S, D, Items}.

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
            neg_inf -> 0;
            inf -> erlang:error({js_error, range_error, <<"Invalid string length">>});
            Num -> trunc(as_float(Num))
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

%% Coerce one argument to a code point per §22.1.2.2 (steps 2a–2c): ToNumber,
%% then a non-integral value, a value < 0, or a value > 0x10FFFF is a RangeError
%% — NOT a TypeError. `nan`/±Infinity from coercion are non-integral, so they
%% are RangeErrors too.
code_point_of(C) ->
    case coerce_num(C) of
        N when is_number(N) ->
            I = trunc(N),
            case I == N andalso I >= 0 andalso I =< 16#10FFFF of
                true -> I;
                false -> erlang:error({js_error, range_error, <<"Invalid code point">>})
            end;
        _ ->
            erlang:error({js_error, range_error, <<"Invalid code point">>})
    end.

%% String.raw(template, ...substitutions) — the default tagged-template tag
%% (§22.1.2.4): concatenate the RAW literal segments (template.raw), inserting
%% ToString(substitution[i]) after each segment except the last. A missing
%% substitution is `undefined` ("undefined"). `Subs` is the cons-list of args.
string_raw(Template, Subs) ->
    %% `raw` may be ANY object (§22.1.2.4 treats it as an array-like, not a
    %% dense array): read `raw.length` via ToLength and each segment via
    %% Get(raw, ToString(i)). Reads dispatch through get_prop, so a genuine
    %% array (the tagged-template case) and a plain object both work.
    Raw = get_prop(Template, <<"raw">>),
    Len = to_length(get_prop(Raw, <<"length">>)),
    raw_join(Raw, Subs, Len, 0, <<>>).

%% Concatenate ToString(Get(raw, "0..Len-1")), inserting ToString(Subs[i])
%% between consecutive segments. `Len =< 0` yields "" (the guard below). A
%% missing substitution contributes the empty string, not "undefined"
%% (§22.1.2.4 appends a substitution only when index+1 < Len).
raw_join(_Raw, _Subs, Len, Idx, Acc) when Idx >= Len ->
    Acc;
raw_join(Raw, Subs, Len, Idx, Acc) ->
    Seg = to_string(get_prop(Raw, integer_to_binary(Idx))),
    Acc1 = <<Acc/binary, Seg/binary>>,
    case Idx + 1 >= Len of
        true ->
            Acc1;
        false ->
            {Sub, Subs1} =
                case Subs of
                    [S | R] -> {to_string(S), R};
                    [] -> {<<>>, []}
                end,
            raw_join(Raw, Subs1, Len, Idx + 1, <<Acc1/binary, Sub/binary>>)
    end.

%% ── Date ─────────────────────────────────────────────────
%% A Date value is a cell `{js_date, Ms}` where `Ms` is an INTEGER count of
%% milliseconds since the Unix epoch (UTC), or the atom `nan` for an Invalid Date.
%% Only the time-value is stored; every getter derives its component on demand via
%% a civil<->days conversion (Howard Hinnant's algorithm), which is exact across the
%% whole ±8.64e15 ms TimeClip range including proleptic (negative) years — unlike
%% `calendar`, whose gregorian-seconds domain excludes years before 0.
%%
%% DEVIATION (documented, deterministic): local time is treated as identical to UTC.
%% So `getFullYear`==`getUTCFullYear` (and likewise for every field), the component
%% form `new Date(y, m, …)` and `Date.UTC(…)` both build a UTC instant,
%% `getTimezoneOffset()` is 0, and an ISO string with no timezone is read as UTC.
%% This removes any host-timezone dependence from compiled programs.
%% NOT implemented (v1 gaps): the setter family (setUTCFullYear/…), the locale/long
%% string forms (toString renders ISO, not the JS long local form), Symbol.toPrimitive,
%% and parsing of the non-ISO `toString`/`toUTCString` layouts.

%% Milliseconds per day — the fundamental Date day boundary.
-define(MS_PER_DAY, 86400000).
%% The maximum absolute time value a Date may hold (TimeClip): 100,000,000 days.
-define(MAX_TIME, 8640000000000000).

%% Date.now() — milliseconds since the Unix epoch.
date_now() ->
    erlang:system_time(millisecond).

%% `new Date(...)` — build a Date cell from the constructor arguments (a cons list):
%%   []            → the current instant (like `Date.now()`).
%%   [v]           → a Date is copied; a string is parsed as ISO 8601 (§21.4.1.15);
%%                   anything else is `ToNumber`'d then TimeClip'd.
%%   [y, m | more] → the component form (year, month, [date, hours, min, sec, ms]),
%%                   interpreted as UTC (see the module deviation note).
%% Always returns a fresh `{js_date, Ms}` cell (Ms an integer or `nan`).
date_new([]) ->
    cell_new({js_date, erlang:system_time(millisecond)});
date_new([V]) ->
    Ms =
        case cell_tag(V) of
            {js_date, M} -> M;
            _ ->
                case js_type(V) of
                    string -> parse_iso(V);
                    _ -> time_clip(coerce_num(V))
                end
        end,
    cell_new({js_date, Ms});
date_new(Args) ->
    cell_new({js_date, make_time_value(Args)}).

%% `Date.UTC(year [, month [, date [, hours [, minutes [, seconds [, ms]]]]]])`
%% (§21.4.3.4) — the time value (a NUMBER: ms since epoch, or NaN), NOT a Date.
date_utc(Args) ->
    out_ms(make_time_value(Args)).

%% `Date.parse(string)` (§21.4.3.2) — `ToString` then parse as ISO 8601; the time
%% value (ms) or NaN when unparseable.
date_parse(V) ->
    out_ms(parse_iso(to_string(V))).

%% A Date instance method dispatched on the receiver's tag. When `Recv` is a Date
%% cell the field/derived value is computed from its ms; otherwise the call DELEGATES
%% to a same-named user method (so `getTime`/`valueOf`/… never clobber a user object's
%% own method). `Name` is the JS method name (a binary); `Args` the full argument list.
date_call(Recv, Name, Args) ->
    case cell_tag(Recv) of
        {js_date, Ms} -> date_field(Name, Ms, Args);
        %% a primitive wrapper: `valueOf` unwraps to the boxed primitive, `toString`
        %% to its string form; no other method exists on a wrapper in this v1 model.
        {js_wrapper, _Kind, Prim} ->
            case Name of
                <<"valueOf">> -> Prim;
                <<"toString">> -> to_string(Prim);
                _ -> type_error(Recv)
            end;
        _ -> delegate(Recv, Name, Args)
    end.

%% Resolve one Date method against a time value `Ms` (integer or `nan`).
%% `getTime`/`valueOf` return the raw time value; `toISOString` throws a RangeError on
%% an Invalid Date (§21.4.4.36); `toJSON` yields `null` there; every other getter
%% yields NaN. All fields are UTC (module deviation).
date_field(<<"getTime">>, Ms, _) -> out_ms(Ms);
date_field(<<"valueOf">>, Ms, _) -> out_ms(Ms);
date_field(<<"getTimezoneOffset">>, nan, _) -> js_nan;
date_field(<<"getTimezoneOffset">>, _Ms, _) -> 0;
date_field(<<"toISOString">>, nan, _) -> range_error(<<"Invalid time value">>);
date_field(<<"toISOString">>, Ms, _) -> to_iso_string(Ms);
date_field(<<"toJSON">>, nan, _) -> null;
date_field(<<"toJSON">>, Ms, _) -> to_iso_string(Ms);
date_field(_Name, nan, _) -> js_nan;
date_field(Name, Ms, _) -> date_component(Name, Ms).

%% The value of a per-field getter (`Ms` is a valid integer time value). Month is
%% 0-based (§21.4.1.5); day-of-week is 0=Sunday (1970-01-01 was a Thursday, day 4).
%% Local and UTC variants coincide (module deviation).
date_component(Name, Ms) ->
    MsOfDay = floor_mod(Ms, ?MS_PER_DAY),
    Days = (Ms - MsOfDay) div ?MS_PER_DAY,
    case Name of
        <<"getFullYear">> -> element(1, civil_from_days(Days));
        <<"getUTCFullYear">> -> element(1, civil_from_days(Days));
        <<"getMonth">> -> element(2, civil_from_days(Days)) - 1;
        <<"getUTCMonth">> -> element(2, civil_from_days(Days)) - 1;
        <<"getDate">> -> element(3, civil_from_days(Days));
        <<"getUTCDate">> -> element(3, civil_from_days(Days));
        <<"getDay">> -> floor_mod(Days + 4, 7);
        <<"getUTCDay">> -> floor_mod(Days + 4, 7);
        <<"getHours">> -> MsOfDay div 3600000;
        <<"getUTCHours">> -> MsOfDay div 3600000;
        <<"getMinutes">> -> (MsOfDay div 60000) rem 60;
        <<"getUTCMinutes">> -> (MsOfDay div 60000) rem 60;
        <<"getSeconds">> -> (MsOfDay div 1000) rem 60;
        <<"getUTCSeconds">> -> (MsOfDay div 1000) rem 60;
        <<"getMilliseconds">> -> MsOfDay rem 1000;
        <<"getUTCMilliseconds">> -> MsOfDay rem 1000;
        _ -> type_error(Name)
    end.

%% Build a time value (ms integer or `nan`) from a component argument list, shared by
%% the component-form `new Date(y, m, …)` and `Date.UTC(…)`. Defaults per spec: month
%% +0, date 1, hours/minutes/seconds/ms 0. Any non-finite component ⇒ NaN. The
%% two-digit-year rule (an integer year in 0..99 ⇒ 1900+year) is applied. UTC (deviation).
make_time_value(Args) ->
    Y0 = to_finite_int(arg(Args, 0)),
    Mo = component(Args, 1, 0),
    D = component(Args, 2, 1),
    H = component(Args, 3, 0),
    Mi = component(Args, 4, 0),
    S = component(Args, 5, 0),
    MilS = component(Args, 6, 0),
    case lists:member(nan, [Y0, Mo, D, H, Mi, S, MilS]) of
        true ->
            nan;
        false ->
            Yr =
                case Y0 >= 0 andalso Y0 =< 99 of
                    true -> 1900 + Y0;
                    false -> Y0
                end,
            Day = make_day(Yr, Mo, D),
            Time = H * 3600000 + Mi * 60000 + S * 1000 + MilS,
            time_clip(Day * ?MS_PER_DAY + Time)
    end.

%% `ToNumber(arg[I])` reduced to a finite integer, or the default when the argument is
%% absent. A NaN/±Infinity component becomes the atom `nan` (its presence makes the
%% whole time value NaN, per MakeDay/MakeTime).
component(Args, I, Default) ->
    case length(Args) > I of
        true -> to_finite_int(arg(Args, I));
        false -> Default
    end.

%% `ToNumber` then `ToInteger` (truncate toward zero), or the atom `nan` for a
%% non-finite result (NaN / ±Infinity).
to_finite_int(V) ->
    case coerce_num(V) of
        N when is_integer(N) -> N;
        N when is_float(N) -> trunc(N);
        _ -> nan
    end.

%% MakeDay (§21.4.1.11): the day number (days since epoch) for (year, month0, date),
%% normalizing month overflow into the year and adding `date-1` days to the 1st of
%% the resulting month (so day 0, day 32, month 13, negative days all roll correctly).
make_day(Y, M, D) ->
    YM = Y + floor_div(M, 12),
    MN = floor_mod(M, 12),
    days_from_civil(YM, MN + 1, 1) + (D - 1).

%% TimeClip (§21.4.1.31): a non-finite value or one whose magnitude exceeds 8.64e15
%% clips to NaN; otherwise ToInteger (a -0 collapses to +0). Accepts the internal
%% numeric domain (integer | float | nan | inf | neg_inf) and yields an integer or `nan`.
time_clip(nan) -> nan;
time_clip(inf) -> nan;
time_clip(neg_inf) -> nan;
time_clip(N) when is_integer(N) -> clip_int(N);
time_clip(N) when is_float(N) -> clip_int(trunc(N)).

clip_int(N) ->
    case abs(N) =< ?MAX_TIME of
        true -> N;
        false -> nan
    end.

%% Internal time value → external JS number (the `nan` atom becomes the `js_nan` sentinel).
out_ms(nan) -> js_nan;
out_ms(N) -> N.

%% `Date.prototype.toISOString`-format string for a valid integer time value:
%% `YYYY-MM-DDTHH:mm:ss.sssZ`, with the expanded `±YYYYYY` year form outside 0..9999
%% (§21.4.4.36 / §21.4.1.33).
to_iso_string(Ms) ->
    MsOfDay = floor_mod(Ms, ?MS_PER_DAY),
    Days = (Ms - MsOfDay) div ?MS_PER_DAY,
    {Y, Mo, D} = civil_from_days(Days),
    H = MsOfDay div 3600000,
    Mi = (MsOfDay div 60000) rem 60,
    S = (MsOfDay div 1000) rem 60,
    MilS = MsOfDay rem 1000,
    iolist_to_binary(
        io_lib:format(
            "~s-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ",
            [iso_year(Y), Mo, D, H, Mi, S, MilS]
        )
    ).

%% The ISO year field: 4 digits in 0..9999, otherwise a signed 6-digit expanded year.
iso_year(Y) when Y >= 0, Y =< 9999 -> io_lib:format("~4..0B", [Y]);
iso_year(Y) when Y < 0 -> io_lib:format("-~6..0B", [-Y]);
iso_year(Y) -> io_lib:format("+~6..0B", [Y]).

%% A Date's string form (used by `to_string`): ISO for a valid date, "Invalid Date"
%% for NaN. DEVIATION: real `Date.prototype.toString` renders the long LOCAL form; we
%% emit the ISO (UTC) string so the result is deterministic and timezone-free.
date_to_string(nan) -> <<"Invalid Date">>;
date_to_string(Ms) -> to_iso_string(Ms).

%% Parse an ISO 8601 Date Time String (§21.4.1.15) into an integer time value or `nan`.
%% Supported: `YYYY`, `YYYY-MM`, `YYYY-MM-DD`, and any of those followed by
%% `THH:mm`, `THH:mm:ss`, `THH:mm:ss.sss`, each optionally with a `Z` or `±HH:mm`
%% timezone; the expanded `±YYYYYY` year is accepted. A date with no time, or a
%% time with no timezone, is read as UTC (module deviation). Unrecognised ⇒ `nan`.
parse_iso(Bin) ->
    RE =
        "^([+-][0-9]{6}|[0-9]{4})(?:-([0-9]{2})(?:-([0-9]{2}))?)?"
        "(?:T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\\.([0-9]{3}))?)?"
        "(Z|[+-][0-9]{2}:[0-9]{2})?)?$",
    case re:run(Bin, RE, [{capture, all_but_first, binary}]) of
        %% `re` truncates trailing non-participating groups, so a date-only string
        %% yields fewer than 8 captures — pad the absent (time/zone) fields with `<<>>`.
        {match, Parts} -> iso_parts_to_ms(pad_to(Parts, 8));
        nomatch -> nan
    end.

%% Right-pad `L` with empty binaries until it has at least `N` elements.
pad_to(L, N) when length(L) >= N -> L;
pad_to(L, N) -> pad_to(L ++ [<<>>], N).

iso_parts_to_ms([Ys, Mos, Ds, Hs, Mis, Ss, MilSs, Tz]) ->
    Y = signed_int(Ys),
    Mo = default_int(Mos, 1),
    D = default_int(Ds, 1),
    H = default_int(Hs, 0),
    Mi = default_int(Mis, 0),
    S = default_int(Ss, 0),
    MilS = default_int(MilSs, 0),
    %% Year 0 is positive and must be written `+000000`; the extended form `-000000`
    %% (negative zero) is explicitly invalid (§21.4.1.15.1).
    NegZeroYear = Y =:= 0 andalso is_negative_year(Ys),
    case NegZeroYear orelse not valid_iso(Mo, D, H, Mi, S) of
        true ->
            nan;
        false ->
            Day = days_from_civil(Y, Mo, D),
            Local = Day * ?MS_PER_DAY + H * 3600000 + Mi * 60000 + S * 1000 + MilS,
            %% Subtract the parsed offset to reach UTC; an absent offset means UTC here.
            time_clip(Local - tz_offset_ms(Tz))
    end.

%% Basic field-range validation (a stricter per-month day check is a v1 gap); an
%% out-of-range field makes the whole string unparseable (NaN).
valid_iso(Mo, D, H, Mi, S) ->
    Mo >= 1 andalso Mo =< 12 andalso
        D >= 1 andalso D =< 31 andalso
        H >= 0 andalso H =< 24 andalso
        Mi >= 0 andalso Mi =< 59 andalso
        S >= 0 andalso S =< 59.

%% Milliseconds to SUBTRACT from a parsed local time to reach UTC. `Z` and an absent
%% offset are both 0 (absent time zones are treated as UTC — deviation).
tz_offset_ms(<<>>) -> 0;
tz_offset_ms(<<"Z">>) -> 0;
tz_offset_ms(<<Sign, H1, H0, $:, M1, M0>>) ->
    Mins = (H1 - $0) * 600 + (H0 - $0) * 60 + (M1 - $0) * 10 + (M0 - $0),
    case Sign of
        $- -> -Mins * 60000;
        _ -> Mins * 60000
    end.

%% An ISO integer field, or `Default` when the capture is absent (empty binary).
default_int(<<>>, Default) -> Default;
default_int(Bin, _) -> binary_to_integer(Bin).

%% Parse a possibly `+`-signed integer (`binary_to_integer` rejects a leading `+`).
signed_int(<<"+", Rest/binary>>) -> binary_to_integer(Rest);
signed_int(Bin) -> binary_to_integer(Bin).

%% Whether an ISO year field carried an explicit minus sign (to reject `-000000`).
is_negative_year(<<"-", _/binary>>) -> true;
is_negative_year(_) -> false.

%% Floored integer division / modulo (Erlang `div`/`rem` truncate toward zero; Date
%% arithmetic needs flooring so negative times land in the right day/field bucket).
floor_div(A, B) -> (A - floor_mod(A, B)) div B.
floor_mod(A, B) -> ((A rem B) + B) rem B.

%% days_from_civil / civil_from_days — Howard Hinnant's proleptic-Gregorian
%% calendar algorithm (public domain). `days_from_civil(Y, M, D)` returns the day
%% number (days since 1970-01-01) for a 1-based month `M` (1..12) and day `D`;
%% `civil_from_days(Z)` inverts it to `{Year, Month1, Day}` with a 1-based month.
%% Both are exact for any integer year, so they cover the full Date range.
days_from_civil(Y0, M, D) ->
    Y = case M =< 2 of
        true -> Y0 - 1;
        false -> Y0
    end,
    Era = case Y >= 0 of
        true -> Y;
        false -> Y - 399
    end div 400,
    Yoe = Y - Era * 400,
    MP = case M > 2 of
        true -> M - 3;
        false -> M + 9
    end,
    Doy = (153 * MP + 2) div 5 + D - 1,
    Doe = Yoe * 365 + Yoe div 4 - Yoe div 100 + Doy,
    Era * 146097 + Doe - 719468.

civil_from_days(Z0) ->
    Z = Z0 + 719468,
    Era = case Z >= 0 of
        true -> Z;
        false -> Z - 146096
    end div 146097,
    Doe = Z - Era * 146097,
    Yoe = (Doe - Doe div 1460 + Doe div 36524 - Doe div 146096) div 365,
    Y = Yoe + Era * 400,
    Doy = Doe - (365 * Yoe + Yoe div 4 - Yoe div 100),
    MP = (5 * Doy + 2) div 153,
    D = Doy - (153 * MP + 2) div 5 + 1,
    M = case MP < 10 of
        true -> MP + 3;
        false -> MP - 9
    end,
    Year = case M =< 2 of
        true -> Y + 1;
        false -> Y
    end,
    {Year, M, D}.

%% A JS RangeError (§21.4.4.36 throws this for an out-of-range Date on toISOString).
range_error(Detail) -> erlang:error({js_error, range_error, Detail}).

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

%% Pad (with `undefined`) or truncate an argument list to exactly N elements —
%% so a runtime `new C(...args)` can call the fixed-arity `C$constructor`.
fit_list(_L, N) when N =< 0 -> [];
fit_list([], N) -> [undefined | fit_list([], N - 1)];
fit_list([X | Xs], N) -> [X | fit_list(Xs, N - 1)].

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
        {js_gen, _} -> array_push(Target, drain_gen(Value, []));
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

%% Live own-element read at integer index `I` of the array cell `Recv`.
%% Returns `{ok, Value}` when index `I` currently holds an own element, or
%% `error` for a hole / out-of-range index. The cell is re-read on every call
%% so that a callback which mutates the array mid-iteration is observed — this
%% is the per-step HasProperty + Get against the live object the spec requires.
arr_index(Recv, I) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_array, _Len, Map} -> maps:find(I, Map);
        _ -> error
    end;
arr_index(_Recv, _I) ->
    error.

%% Live `Get(Recv, I)`: the element at index `I`, or `undefined` for a hole /
%% out-of-range index. Used by find/findIndex/findLast/findLastIndex, which
%% visit every index in range without a HasProperty (present-element) check.
arr_get_live(Recv, I) ->
    case arr_index(Recv, I) of
        {ok, V} -> V;
        error -> undefined
    end.

%% reduce(fn, init) — left fold seeded by `init`. Skips holes (per-step
%% present-element check) and re-reads the live array each step; the iteration
%% bound `Len` is fixed at entry so elements the callback appends beyond the
%% original length are never visited. Callback: (accumulator, element, index, array).
array_reduce(Recv, Fn, Init) ->
    {Len, _Map} = arr_content(Recv),
    areduce(Fn, Recv, 0, Len, Init).
areduce(_, _, K, Len, Acc) when K >= Len -> Acc;
areduce(Fn, Arr, K, Len, Acc) ->
    case arr_index(Arr, K) of
        {ok, X} -> areduce(Fn, Arr, K + 1, Len, call_cb(Fn, [Acc, X, K, Arr]));
        error -> areduce(Fn, Arr, K + 1, Len, Acc)
    end.

%% reduce(fn) — no seed: the first present element seeds the accumulator and the
%% fold continues after it. An array with no present element in range → TypeError.
array_reduce1(Recv, Fn) ->
    {Len, _Map} = arr_content(Recv),
    case reduce_seed_l(Recv, 0, Len) of
        error -> type_error(Recv);
        {ok, K0, Seed} -> areduce(Fn, Recv, K0 + 1, Len, Seed)
    end.

%% First present index at/after `K` (below `Len`); `{ok, Index, Value}` or `error`.
reduce_seed_l(_Arr, K, Len) when K >= Len -> error;
reduce_seed_l(Arr, K, Len) ->
    case arr_index(Arr, K) of
        {ok, X} -> {ok, K, X};
        error -> reduce_seed_l(Arr, K + 1, Len)
    end.

%% reduceRight(fn, init?) — right fold (last index down to 0), mirroring reduce:
%% holes skipped, live re-read, callback gets (accumulator, element, index, array).
array_reduce_right(Recv, Fn, Init) ->
    {Len, _Map} = arr_content(Recv),
    arredr(Fn, Recv, Len - 1, Init).
arredr(_, _, K, Acc) when K < 0 -> Acc;
arredr(Fn, Arr, K, Acc) ->
    case arr_index(Arr, K) of
        {ok, X} -> arredr(Fn, Arr, K - 1, call_cb(Fn, [Acc, X, K, Arr]));
        error -> arredr(Fn, Arr, K - 1, Acc)
    end.

%% reduceRight(fn) — no seed: the last present element seeds it; all-holes → TypeError.
array_reduce_right1(Recv, Fn) ->
    {Len, _Map} = arr_content(Recv),
    case reduce_seed_r(Recv, Len - 1) of
        error -> type_error(Recv);
        {ok, K0, Seed} -> arredr(Fn, Recv, K0 - 1, Seed)
    end.

%% First present index at/below `K` (down to 0); `{ok, Index, Value}` or `error`.
reduce_seed_r(_Arr, K) when K < 0 -> error;
reduce_seed_r(Arr, K) ->
    case arr_index(Arr, K) of
        {ok, X} -> {ok, K, X};
        error -> reduce_seed_r(Arr, K - 1)
    end.

%% some(fn) — true if the callback is truthy for any present element. Skips holes,
%% re-reads the live array, and bounds iteration by the length captured at entry.
array_some(Recv, Fn) ->
    {Len, _Map} = arr_content(Recv),
    asome(Fn, Recv, 0, Len).
asome(_, _, K, Len) when K >= Len -> false;
asome(Fn, Arr, K, Len) ->
    case arr_index(Arr, K) of
        {ok, X} ->
            case truthy(call_cb(Fn, [X, K, Arr])) of
                1 -> true;
                0 -> asome(Fn, Arr, K + 1, Len)
            end;
        error ->
            asome(Fn, Arr, K + 1, Len)
    end.

%% every(fn) — true unless the callback is falsy for some present element. Skips
%% holes, re-reads the live array, bounds iteration by the entry length.
array_every(Recv, Fn) ->
    {Len, _Map} = arr_content(Recv),
    aevery(Fn, Recv, 0, Len).
aevery(_, _, K, Len) when K >= Len -> true;
aevery(Fn, Arr, K, Len) ->
    case arr_index(Arr, K) of
        {ok, X} ->
            case truthy(call_cb(Fn, [X, K, Arr])) of
                0 -> false;
                1 -> aevery(Fn, Arr, K + 1, Len)
            end;
        error ->
            aevery(Fn, Arr, K + 1, Len)
    end.

%% find(fn) — the first element for which the callback is truthy, else undefined.
%% Visits EVERY index in [0, Len) (no hole skip; a hole reads as undefined) and
%% re-reads the live array each step.
array_find(Recv, Fn) ->
    {Len, _Map} = arr_content(Recv),
    afind(Fn, Recv, 0, Len).
afind(_, _, K, Len) when K >= Len -> undefined;
afind(Fn, Arr, K, Len) ->
    X = arr_get_live(Arr, K),
    case truthy(call_cb(Fn, [X, K, Arr])) of
        1 -> X;
        0 -> afind(Fn, Arr, K + 1, Len)
    end.

%% findIndex(fn) — the first index for which the callback is truthy, else -1.
%% Same visiting rule as find: every index in range, live re-read.
array_find_index(Recv, Fn) ->
    {Len, _Map} = arr_content(Recv),
    afindi(Fn, Recv, 0, Len).
afindi(_, _, K, Len) when K >= Len -> -1;
afindi(Fn, Arr, K, Len) ->
    X = arr_get_live(Arr, K),
    case truthy(call_cb(Fn, [X, K, Arr])) of
        1 -> K;
        0 -> afindi(Fn, Arr, K + 1, Len)
    end.

%% arr.flatMap(fn) — map then flatten one level. Skips holes (present-element
%% check), re-reads the live array, and bounds iteration by the entry length.
array_flat_map(Recv, Fn) ->
    {Len, _Map} = arr_content(Recv),
    new_array(aflatmap(Fn, Recv, 0, Len)).
aflatmap(_, _, K, Len) when K >= Len -> [];
aflatmap(Fn, Arr, K, Len) ->
    case arr_index(Arr, K) of
        {ok, X} -> flat_one(call_cb(Fn, [X, K, Arr])) ++ aflatmap(Fn, Arr, K + 1, Len);
        error -> aflatmap(Fn, Arr, K + 1, Len)
    end.

index_pairs(L) -> index_pairs(L, 0).
index_pairs([], _) -> [];
index_pairs([X | Xs], I) -> [{X, I} | index_pairs(Xs, I + 1)].

%% arr.findLast(fn) / findLastIndex(fn) — like find/findIndex from the end:
%% visit every index from Len-1 down to 0 (a hole reads as undefined), live re-read.
array_find_last(Recv, Fn) ->
    {Len, _Map} = arr_content(Recv),
    afind_last(Fn, Recv, Len - 1).
afind_last(_, _, K) when K < 0 -> undefined;
afind_last(Fn, Arr, K) ->
    X = arr_get_live(Arr, K),
    case truthy(call_cb(Fn, [X, K, Arr])) of
        1 -> X;
        0 -> afind_last(Fn, Arr, K - 1)
    end.

array_find_last_index(Recv, Fn) ->
    {Len, _Map} = arr_content(Recv),
    afind_last_i(Fn, Recv, Len - 1).
afind_last_i(_, _, K) when K < 0 -> -1;
afind_last_i(Fn, Arr, K) ->
    X = arr_get_live(Arr, K),
    case truthy(call_cb(Fn, [X, K, Arr])) of
        1 -> K;
        0 -> afind_last_i(Fn, Arr, K - 1)
    end.

%% arr.lastIndexOf(x) — last strict-equal index, or -1.
%% lastIndexOf(searchElement, fromIndex) — the highest === index at or before
%% `fromIndex` (default len-1; ToIntegerOrInfinity, negatives from the end), else -1.
array_last_index_of(Recv, X, From) when is_binary(Recv) ->
    str_last_index_of(Recv, X, From);
array_last_index_of(Recv, X, From) ->
    {Len, Map} = arr_content(Recv),
    Cap = last_idx_from(From, Len),
    Pairs = [P || {_E, I} = P <- index_pairs(arr_list(Len, Map)), I =< Cap],
    alast_idx(Pairs, X, -1).

last_idx_from(undefined, Len) ->
    Len - 1;
last_idx_from(From, Len) ->
    case coerce_num(From) of
        nan -> 0;
        neg_inf -> -1;
        inf -> Len - 1;
        N ->
            V = trunc(as_float(N)),
            case V >= 0 of
                true -> min(V, Len - 1);
                false -> Len + V
            end
    end.

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

%% num.toString(radix) — base-`radix` (2..36) string; radix 10 (or an out-of-range
%% radix, which the spec would RangeError but this v1 tolerates) falls back to the
%% default ToString. Integer-valued numbers render as the base-R integer whether
%% they are held as an Erlang integer or an integral float (e.g. 510/2 = 255.0 →
%% "ff", not the base-10 "255"); genuine fractions render "<int>.<frac>" with the
%% fraction expanded digit by digit — terminating exactly for dyadic fractions
%% (0.5 → "0.1") and bounded otherwise. NaN / ±Infinity stringify as usual.
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
                    radix_int_str(Num, R);
                Num when is_float(Num) ->
                    radix_float_str(Num, R);
                _ ->
                    to_string(N)
            end
    end.

%% Signed base-R rendering of an integer, lowercased ("-ff", "10000").
radix_int_str(Num, R) ->
    list_to_binary(string:lowercase(integer_to_list(Num, R))).

%% Signed base-R rendering of a float: integral floats reuse the integer path,
%% otherwise "<int>.<frac>". ±0.0 → "0".
radix_float_str(F, _R) when F == 0.0 ->
    <<"0">>;
radix_float_str(F, R) when F < 0 ->
    <<"-", (radix_float_str(-F, R))/binary>>;
radix_float_str(F, R) ->
    IntPart = trunc(F),
    Frac = F - IntPart,
    case Frac == 0.0 of
        true ->
            radix_int_str(IntPart, R);
        false ->
            IntStr = radix_int_str(IntPart, R),
            FracStr = radix_frac_digits(Frac, R, 1100, <<>>),
            <<IntStr/binary, ".", FracStr/binary>>
    end.

%% Base-R digits of a fraction in [0,1): multiply by R, emit the integer part as
%% the next digit, repeat until the remainder is exactly 0 (dyadic fractions
%% terminate) or `Max` digits have been emitted (the bound for repeating ones).
radix_frac_digits(_Frac, _R, 0, Acc) ->
    Acc;
radix_frac_digits(Frac, R, Max, Acc) ->
    Scaled = Frac * R,
    D = trunc(Scaled),
    Rem = Scaled - D,
    Acc2 = <<Acc/binary, (radix_digit(D))>>,
    case Rem == 0.0 of
        true -> Acc2;
        false -> radix_frac_digits(Rem, R, Max - 1, Acc2)
    end.

%% A single base-36 digit value (0..35) as its lowercase character (0-9, a-z).
radix_digit(D) when D >= 0, D =< 9 -> $0 + D;
radix_digit(D) when D >= 10, D =< 35 -> $a + (D - 10).

%% num.toExponential(d) — exponential notation with `d` fraction digits (undefined
%% → as many digits as needed to represent the value uniquely). Erlang's scientific
%% format zero-pads the exponent to two digits (`e+02`); JS uses the minimal
%% exponent (`e+2`), so the exponent is de-padded afterwards.
num_to_exponential(N, D) ->
    case coerce_num(N) of
        nan ->
            <<"NaN">>;
        inf ->
            <<"Infinity">>;
        neg_inf ->
            <<"-Infinity">>;
        Num ->
            F = as_float(Num),
            Raw =
                case coerce_num(D) of
                    nan -> exp_shortest(F, 0);
                    Dn -> float_to_binary(F, [{scientific, max(0, trunc(as_float(Dn)))}])
                end,
            fix_exp(Raw)
    end.

%% The fewest fraction digits whose scientific rendering of `F` round-trips to `F`.
exp_shortest(F, D) when D >= 17 ->
    float_to_binary(F, [{scientific, 17}]);
exp_shortest(F, D) ->
    B = float_to_binary(F, [{scientific, D}]),
    case reparse_sci(B) =:= F of
        true -> B;
        false -> exp_shortest(F, D + 1)
    end.

%% Parse an Erlang scientific literal back to a float. binary_to_float REQUIRES a
%% decimal point, but the 0-fraction-digit form ("1e+02") has none — insert ".0"
%% before the exponent for the reparse only.
reparse_sci(B) ->
    case binary:split(B, <<"e">>) of
        [M, E] ->
            M2 =
                case binary:match(M, <<".">>) of
                    nomatch -> <<M/binary, ".0">>;
                    _ -> M
                end,
            binary_to_float(<<M2/binary, "e", E/binary>>);
        _ ->
            binary_to_float(B)
    end.

%% De-pad the exponent of an Erlang scientific literal: `1.23e+02` → `1.23e+2`.
fix_exp(Bin) ->
    case binary:split(Bin, <<"e">>) of
        [Mant, <<Sign, Digits/binary>>] ->
            <<Mant/binary, "e", Sign, (strip_leading_zeros(Digits))/binary>>;
        _ ->
            Bin
    end.

strip_leading_zeros(<<"0", R/binary>>) when R =/= <<>> -> strip_leading_zeros(R);
strip_leading_zeros(D) -> D.

%% num.toPrecision(p) — `p` significant digits, in fixed or exponential notation
%% per the spec (exponential when the decimal exponent e is < -6 or >= p, else
%% fixed). With no precision it is ToString. Reuses toFixed/scientific formatting.
num_to_precision(N, P) ->
    case coerce_num(P) of
        nan ->
            to_string(N);
        Pn ->
            case coerce_num(N) of
                nan -> <<"NaN">>;
                inf -> <<"Infinity">>;
                neg_inf -> <<"-Infinity">>;
                Num -> precision_go(as_float(Num), max(1, trunc(as_float(Pn))))
            end
    end.

precision_go(F, P) when F == 0 ->
    num_to_fixed(0.0, P - 1);
precision_go(F, P) ->
    Sci = float_to_binary(F, [{scientific, P - 1}]),
    E = sci_exponent(Sci),
    case E < -6 orelse E >= P of
        true -> fix_exp(Sci);
        false -> num_to_fixed(F, P - 1 - E)
    end.

%% The decimal exponent encoded in an Erlang scientific literal ("1.2e+05" → 5).
sci_exponent(Sci) ->
    [_, <<Sign, Digits/binary>>] = binary:split(Sci, <<"e">>),
    N = binary_to_integer(Digits),
    case Sign of
        $- -> -N;
        _ -> N
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

%% indexOf(searchElement, fromIndex) — first === index at or after `fromIndex`
%% (ToIntegerOrInfinity, negatives from the end, clamped), else -1. A string
%% receiver does a substring search honouring the `position` argument.
array_index_of(Recv, X, From) when is_binary(Recv) -> str_index_of(Recv, X, From);
array_index_of(Recv, X, From) ->
    {Len, Map} = arr_content(Recv),
    Start = idx_from(From, Len),
    aidx(lists:nthtail(min(Start, Len), arr_list(Len, Map)), Start, X).

idx_from(From, Len) ->
    case coerce_num(From) of
        nan -> 0;
        neg_inf -> 0;
        inf -> Len;
        N ->
            V = trunc(as_float(N)),
            case V < 0 of
                true -> max(Len + V, 0);
                false -> V
            end
    end.

aidx([], _, _) -> -1;
aidx([E | Es], I, X) ->
    case strict_eq(E, X) of
        1 -> I;
        0 -> aidx(Es, I + 1, X)
    end.

%% includes → a JS boolean atom. Unlike indexOf (which uses ===), Array.includes
%% uses SameValueZero, so `[NaN].includes(NaN)` is true.
%% includes(searchElement, fromIndex) — SameValueZero search from `fromIndex`
%% (ToIntegerOrInfinity, negatives from the end, clamped). A string receiver does a
%% substring test (its position argument is not yet honoured).
array_includes(Recv, X, From) when is_binary(Recv) ->
    str_index_of(Recv, X, From) =/= -1;
array_includes(Recv, X, From) ->
    {Len, Map} = arr_content(Recv),
    Start =
        case coerce_num(From) of
            nan -> 0;
            neg_inf -> 0;
            inf -> Len;
            N ->
                V = trunc(as_float(N)),
                case V < 0 of
                    true -> max(Len + V, 0);
                    false -> V
                end
        end,
    a_incl(lists:nthtail(min(Start, Len), arr_list(Len, Map)), X).
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
%% arr.sort(cmp?) — sort in place, returning the array. Per SortIndexedProperties
%% + SortCompare (ES2023 23.1.3.30): only *present* elements are sorted; holes are
%% moved to the very end. `undefined` elements are never handed to a comparator and
%% always sort after every non-undefined element (but before holes). With no `cmp`,
%% elements are ordered by ToString; with a `cmp`, by the sign of `cmp(a, b)` (a NaN
%% comparator result is treated as 0, i.e. keep order). The sort is stable.
array_sort(Recv, Cmp) ->
    {Len, Map} = arr_content(Recv),
    %% Present elements in index order (holes skipped via the own-key check).
    Present = [maps:get(I, Map) || I <- lists:seq(0, Len - 1), maps:is_key(I, Map)],
    {Undef, Defined} = lists:partition(fun(V) -> V =:= undefined end, Present),
    Sorted =
        case Cmp of
            undefined -> lists:sort(fun(A, B) -> to_string(A) =< to_string(B) end, Defined);
            _ -> lists:sort(fun(A, B) -> sort_lte(call_cb(Cmp, [A, B])) end, Defined)
        end,
    %% Non-undefined (sorted), then the undefined run; the remaining tail
    %% [length(Ordered)..Len-1] is left as holes (absent keys), preserving Len.
    Ordered = Sorted ++ Undef,
    NewMap = maps:from_list(lists:zip(lists:seq(0, length(Ordered) - 1), Ordered)),
    erlang:put(?CELL_KEY(Recv), {js_array, Len, NewMap}),
    Recv.

sort_lte(V) ->
    case coerce_num(V) of
        nan -> true;
        neg_inf -> true;
        inf -> false;
        N -> N =< 0
    end.

%% arr.toReversed() (ES2023 23.1.3.33) — a NEW array with the elements of `arr`
%% in reverse index order. `arr` is not mutated; holes read through as `undefined`
%% so the result is dense with the same length.
array_to_reversed(Recv) ->
    {Len, Map} = arr_content(Recv),
    new_array(lists:reverse(arr_list(Len, Map))).

%% arr.toSorted(cmp?) (ES2023 23.1.3.34) — a NEW sorted array, leaving `arr`
%% unchanged. Unlike `sort`, holes are read THROUGH as `undefined` values (not
%% skipped): every `undefined` sorts after all non-`undefined` elements and the
%% result is dense with the same length. Default order is by ToString; with `cmp`,
%% by the sign of `cmp(a, b)` (a NaN result keeps order). The sort is stable.
array_to_sorted(Recv, Cmp) ->
    {Len, Map} = arr_content(Recv),
    {Undef, Defined} =
        lists:partition(fun(V) -> V =:= undefined end, arr_list(Len, Map)),
    Sorted =
        case Cmp of
            undefined ->
                lists:sort(fun(A, B) -> to_string(A) =< to_string(B) end, Defined);
            _ ->
                lists:sort(fun(A, B) -> sort_lte(call_cb(Cmp, [A, B])) end, Defined)
        end,
    new_array(Sorted ++ Undef).

%% arr.with(index, value) (ES2023 23.1.3.39) — a NEW array equal to `arr` but with
%% the element at `index` replaced by `value`; `arr` is not mutated. `index` is
%% ToIntegerOrInfinity and, when negative, counts from the end (len + index). A
%% resulting index outside [0, len) — including ±Infinity — raises a RangeError.
array_with(Recv, Index, Value) ->
    {Len, Map} = arr_content(Recv),
    Actual =
        case to_int_or_inf(Index) of
            inf -> Len;
            neg_inf -> -1;
            N when N < 0 -> Len + N;
            N -> N
        end,
    case Actual >= 0 andalso Actual < Len of
        true -> new_array(list_replace(arr_list(Len, Map), Actual, Value));
        false -> range_error(<<"Invalid index">>)
    end.

%% Replace the element at 0-based Idx (assumed in range) of List with Value.
list_replace(List, Idx, Value) ->
    {Prefix, [_Old | Rest]} = lists:split(Idx, List),
    Prefix ++ [Value | Rest].

%% arr.toSpliced(start, skipCount, ...items) (ES2023 23.1.3.35) — the array that
%% `splice` would leave the receiver AS, without mutating `arr`: a NEW array with
%% `skipCount` elements removed at `start` and `items` inserted there. `start` and
%% `skipCount` are clamped exactly as for `splice` (see splice_args). `Args` is the
%% cons list of all call arguments.
array_to_spliced(Recv, Args) ->
    {Len, Map} = arr_content(Recv),
    List = arr_list(Len, Map),
    {Start, DelCount, Items} = splice_args(Args, Len),
    Prefix = lists:sublist(List, Start),
    Suffix = lists:nthtail(min(Start + DelCount, Len), List),
    new_array(Prefix ++ Items ++ Suffix).

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

%% str.charAt(pos) → the 1-char string at code-point index `pos`, or "" when
%% out of range. Per §22.1.3.1, `pos` is ToIntegerOrInfinity: ToNumber then
%% truncate toward zero, with NaN/undefined → 0 and ±Infinity out of range. So
%% a non-numeric or fractional argument is coerced ('abcd'.charAt('2') → 'c',
%% 'abc'.charAt(1.9) → 'b'), not silently treated as index 0.
str_char_at(Str, Pos) ->
    case char_at_index(Pos, cps(Str)) of
        {ok, C} -> from_cps([C]);
        error -> <<>>
    end.

%% str.charCodeAt(pos) → the code point at index `pos` as a number, or NaN when
%% out of range. `pos` is ToIntegerOrInfinity, exactly as in str_char_at.
str_char_code_at(Str, Pos) ->
    case char_at_index(Pos, cps(Str)) of
        {ok, C} -> C;
        error -> js_nan
    end.

%% ToIntegerOrInfinity(Pos) → {ok, CodePoint} when the (truncated) index lands
%% in [0, length), else `error`. NaN/undefined → 0; fractions truncate toward
%% zero; ±Infinity are out of range. Shared by charAt and charCodeAt.
char_at_index(Pos, Cps) ->
    case coerce_num(Pos) of
        nan -> nth_code(0, Cps);
        inf -> error;
        neg_inf -> error;
        N -> nth_code(trunc(as_float(N)), Cps)
    end.

nth_code(Idx, Cps) when Idx >= 0 ->
    case Idx < length(Cps) of
        true -> {ok, lists:nth(Idx + 1, Cps)};
        false -> error
    end;
nth_code(_, _) ->
    error.

%% str.codePointAt(i) — like charCodeAt but the position is ToIntegerOrInfinity
%% (undefined/NaN → 0, fractions truncated) and an out-of-range index yields
%% `undefined` (not NaN). (In this code-point-indexed model a code point IS the code
%% unit for BMP text; lone surrogates are unrepresentable — header deviation.)
str_code_point_at(Str, I) ->
    Idx =
        case coerce_num(I) of
            nan -> 0;
            inf -> 16#7FFFFFFF;
            neg_inf -> -1;
            N -> trunc(as_float(N))
        end,
    Cps = cps(Str),
    case Idx >= 0 andalso Idx < length(Cps) of
        true -> lists:nth(Idx + 1, Cps);
        false -> undefined
    end.

str_upper(Str) -> unicode:characters_to_binary(string:uppercase(Str)).
str_lower(Str) -> unicode:characters_to_binary(string:lowercase(Str)).

%% str.normalize(form) — Unicode normalization; form defaults to "NFC". An
%% unrecognized form is a RangeError, per spec.
str_normalize(Str, Form) ->
    case norm_form(Form) of
        nfc -> unicode:characters_to_nfc_binary(Str);
        nfd -> unicode:characters_to_nfd_binary(Str);
        nfkc -> unicode:characters_to_nfkc_binary(Str);
        nfkd -> unicode:characters_to_nfkd_binary(Str);
        error ->
            erlang:error({js_error, range_error, <<"Invalid normalization form">>})
    end.

norm_form(undefined) -> nfc;
norm_form(<<"NFC">>) -> nfc;
norm_form(<<"NFD">>) -> nfd;
norm_form(<<"NFKC">>) -> nfkc;
norm_form(<<"NFKD">>) -> nfkd;
norm_form(_) -> error.

%% str.indexOf(sub, position) — first code-point index of `sub` at or after
%% `position`, else -1. `position` is ToIntegerOrInfinity clamped to [0, len]
%% (NaN/undefined → 0, +Infinity → len). The empty search string is found at
%% min(position, len) (== the clamped start). `sub` is coerced with ToString.
str_index_of(Str, Sub, Pos) ->
    SubBin = to_string(Sub),
    Cps = cps(Str),
    Len = length(Cps),
    Start = str_pos_clamp(Pos, Len),
    case SubBin of
        <<>> ->
            Start;
        _ ->
            StartByte = byte_size(from_cps(lists:sublist(Cps, 1, Start))),
            Tail = binary:part(Str, StartByte, byte_size(Str) - StartByte),
            case binary:match(Tail, SubBin) of
                nomatch -> -1;
                {Pos1, _} -> Start + length(cps(binary:part(Tail, 0, Pos1)))
            end
    end.

%% str.lastIndexOf(sub, position) — the greatest code-point index `i` in
%% [0, start] at which `sub` occurs (overlapping matches count), else -1.
%% Per spec a NaN position (e.g. omitted / undefined) means +Infinity, so the
%% whole string is searched; otherwise `position` is ToIntegerOrInfinity. The
%% start bound is clamped to [0, len]. The empty search string matches at the
%% clamped start. `sub` is coerced with ToString.
str_last_index_of(Str, Sub, Pos) ->
    SubBin = to_string(Sub),
    Cps = cps(Str),
    Len = length(Cps),
    Start = str_last_pos_clamp(Pos, Len),
    SubCps = cps(SubBin),
    SubLen = length(SubCps),
    str_lidx_from(min(Start, Len - SubLen), Cps, SubCps, SubLen).

%% Scan candidate start indices downward from `I`, returning the first (highest)
%% at which `Sub` (a code-point list of length `SubLen`) matches, else -1.
str_lidx_from(I, _Cps, _Sub, _SubLen) when I < 0 -> -1;
str_lidx_from(I, Cps, Sub, SubLen) ->
    case lists:sublist(Cps, I + 1, SubLen) =:= Sub of
        true -> I;
        false -> str_lidx_from(I - 1, Cps, Sub, SubLen)
    end.

%% ToIntegerOrInfinity(V) clamped to the integer range [0, Max]. Used for the
%% forward-search `position` of indexOf/includes/startsWith/endsWith.
str_pos_clamp(V, Max) ->
    case coerce_num(V) of
        nan -> 0;
        neg_inf -> 0;
        inf -> Max;
        N -> min(max(trunc(as_float(N)), 0), Max)
    end.

%% Like str_pos_clamp but a NaN position means +Infinity (search the whole
%% string), matching String.prototype.lastIndexOf's coercion of `position`.
str_last_pos_clamp(V, Max) ->
    case coerce_num(V) of
        nan -> Max;
        neg_inf -> 0;
        inf -> Max;
        N -> min(max(trunc(as_float(N)), 0), Max)
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

%% str.trim() / trimStart() / trimEnd() — remove leading and/or trailing runs
%% of code points that are JS WhiteSpace or LineTerminator (see `is_js_ws/1`).
%% The JS whitespace set differs from Erlang's `string:trim` default (it must
%% include U+FEFF and U+00A0 and excludes non-WhiteSpace Unicode spaces), so we
%% trim against the ECMAScript set explicitly.
str_trim(Str) -> from_cps(trim_trailing(trim_leading(cps(Str)))).
str_trim_start(Str) -> from_cps(trim_leading(cps(Str))).
str_trim_end(Str) -> from_cps(trim_trailing(cps(Str))).

trim_leading([C | Rest]) ->
    case is_js_ws(C) of
        true -> trim_leading(Rest);
        false -> [C | Rest]
    end;
trim_leading([]) ->
    [].

trim_trailing(Cps) -> lists:reverse(trim_leading(lists:reverse(Cps))).

%% True when the code point is ECMAScript WhiteSpace or a LineTerminator
%% (per ECMAScript §12.2/§12.3): tab, LF, VT, FF, CR, space, NBSP, the Unicode
%% "space separator" (Zs) code points, LS/PS, and the ZWNBSP/BOM (U+FEFF).
is_js_ws(16#0009) -> true;
is_js_ws(16#000A) -> true;
is_js_ws(16#000B) -> true;
is_js_ws(16#000C) -> true;
is_js_ws(16#000D) -> true;
is_js_ws(16#0020) -> true;
is_js_ws(16#00A0) -> true;
is_js_ws(16#1680) -> true;
is_js_ws(C) when C >= 16#2000, C =< 16#200A -> true;
is_js_ws(16#2028) -> true;
is_js_ws(16#2029) -> true;
is_js_ws(16#202F) -> true;
is_js_ws(16#205F) -> true;
is_js_ws(16#3000) -> true;
is_js_ws(16#FEFF) -> true;
is_js_ws(_) -> false.

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

%% str.startsWith(prefix, position) — true when `prefix` (ToString) occurs in
%% `str` starting exactly at code-point index `position`. `position` is
%% ToIntegerOrInfinity clamped to [0, len] (undefined/NaN → 0). Returns false
%% when `position` + prefix length would run past the end of the string.
str_starts_with(Str, Prefix, Pos) ->
    P = to_string(Prefix),
    Cps = cps(Str),
    Len = length(Cps),
    Start = str_pos_clamp(Pos, Len),
    PLen = length(cps(P)),
    case Start + PLen > Len of
        true -> false;
        false -> from_cps(lists:sublist(Cps, Start + 1, PLen)) =:= P
    end.

%% str.endsWith(suffix, end_position) — true when `suffix` (ToString) occurs in
%% `str` ending exactly at code-point index `end_position`. When `end_position`
%% is undefined it defaults to len; otherwise it is ToIntegerOrInfinity clamped
%% to [0, len]. Returns false when the suffix would start before index 0.
str_ends_with(Str, Suffix, EndPos) ->
    S = to_string(Suffix),
    Cps = cps(Str),
    Len = length(Cps),
    End =
        case EndPos of
            undefined -> Len;
            _ -> str_pos_clamp(EndPos, Len)
        end,
    SLen = length(cps(S)),
    Start = End - SLen,
    case Start < 0 of
        true -> false;
        false -> from_cps(lists:sublist(Cps, Start + 1, SLen)) =:= S
    end.

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
%%
%% Per sec-parseint-string-radix the leading run of ES `StrWhiteSpaceChar` is
%% removed (the full `?JS_WS` set — NBSP, the Space_Separator block, the line
%% terminators — not just the ASCII blanks Erlang's default trim knows), and the
%% radix is coerced with ToInt32 (mod 2^32, so e.g. 4294967298 ≡ 2, and
%% -2147483650 ≡ 2147483646 which is outside 2..36 → NaN).
parse_int(S, RadixArg) ->
    Str = unicode:characters_to_binary(string:trim(to_string(S), leading, ?JS_WS)),
    {Sign, Rest0} =
        case Str of
            <<"-", R/binary>> -> {-1, R};
            <<"+", R/binary>> -> {1, R};
            _ -> {1, Str}
        end,
    Radix0 = js_to_int32(RadixArg),
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
%% Unlike string:to_float this accepts "1e3" and ".5". Per sec-parsefloat-string
%% the leading run of ES `StrWhiteSpaceChar` (the full `?JS_WS` set) is removed.
parse_float(S) ->
    Str = unicode:characters_to_binary(string:trim(to_string(S), leading, ?JS_WS)),
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

%% ───────────────────────── URI encode / decode ─────────────────────────
%%
%% The four global URI functions (ECMAScript §19.2.6). JS strings are UTF-8
%% binaries here, so encoding is a per-BYTE scan (every unescaped character is
%% ASCII, so this is equivalent to the spec's per-code-point scan) and decoding
%% collects raw octets from %XX escapes and re-validates them as UTF-8. A
%% malformed %-escape, a bad UTF-8 octet sequence (overlong form, surrogate, or
%% code point > U+10FFFF), or an out-of-input truncation is a URIError.
%%
%% NOTE: lone surrogates are unrepresentable in this UTF-8 string model, so the
%% encode-side "unpaired surrogate → URIError" rule never fires here (those
%% inputs cannot be constructed); the tests that exercise it need String
%% surrogate literals and are out of reach for this v1.

%% encodeURIComponent(uriComponent) — percent-encode ToString(x)'s UTF-8 bytes,
%% leaving only uriUnescaped (A-Za-z0-9 and `- _ . ! ~ * ' ( )`) literal.
encode_uri_component(V) -> uri_encode(to_string(V), component).

%% encodeURI(uri) — like encodeURIComponent but ALSO leaves the uriReserved set
%% and `#` (`; / ? : @ & = + $ , #`) literal.
encode_uri(V) -> uri_encode(to_string(V), full).

%% decodeURIComponent(encodedURIComponent) — reverse encodeURIComponent: decode
%% every %XX escape (the reserved set is empty here, so nothing is preserved).
decode_uri_component(V) -> uri_decode(to_string(V), component).

%% decodeURI(encodedURI) — reverse encodeURI: decode %XX escapes, but a single
%% octet whose character is in the reserved set (`; / ? : @ & = + $ , #`) is
%% LEFT as its original escape substring verbatim (case preserved), per §19.2.6.
decode_uri(V) -> uri_decode(to_string(V), full).

%% Percent-encode the UTF-8 binary `Str`. `Mode` selects the unescaped set:
%% `component` keeps only uriUnescaped; `full` also keeps uriReserved ∪ `#`.
uri_encode(Str, Mode) -> uri_encode(Str, Mode, <<>>).

uri_encode(<<>>, _Mode, Acc) ->
    Acc;
uri_encode(<<B, Rest/binary>>, Mode, Acc) ->
    case uri_keep(B, Mode) of
        true -> uri_encode(Rest, Mode, <<Acc/binary, B>>);
        false -> uri_encode(Rest, Mode, <<Acc/binary, $%, (uri_hex2(B))/binary>>)
    end.

%% True if byte `B` must stay literal when encoding in `Mode`.
uri_keep(B, component) -> uri_unescaped(B);
uri_keep(B, full) -> uri_unescaped(B) orelse uri_reserved(B).

%% uriUnescaped :: uriAlpha | DecimalDigit | uriMark
%% (uriMark = `-` `_` `.` `!` `~` `*` `'` `(` `)`).
uri_unescaped(B) ->
    (B >= $A andalso B =< $Z) orelse
        (B >= $a andalso B =< $z) orelse
        (B >= $0 andalso B =< $9) orelse
        lists:member(B, [$-, $_, $., $!, $~, $*, $', $(, $)]).

%% uriReserved ∪ `#` — kept literal by encodeURI, and preserved (not decoded)
%% by decodeURI.
uri_reserved(B) ->
    lists:member(B, [$;, $/, $?, $:, $@, $&, $=, $+, $$, $,, $#]).

%% The two UPPERCASE hex digits of a byte (0..255), as a 2-byte binary.
uri_hex2(B) ->
    <<(uri_hexdig(B bsr 4)), (uri_hexdig(B band 16#0F))>>.

uri_hexdig(N) when N < 10 -> $0 + N;
uri_hexdig(N) -> $A + (N - 10).

%% Decode the UTF-8 binary `Str`. `Mode` = `component` (empty reserved set →
%% decode everything) or `full` (a decoded reserved character is left as its
%% original escape).
uri_decode(Str, Mode) -> uri_decode(Str, Mode, <<>>).

uri_decode(<<>>, _Mode, Acc) ->
    Acc;
uri_decode(<<$%, Rest/binary>>, Mode, Acc) ->
    {B1, R1} = uri_hexbyte(Rest),
    case B1 < 16#80 of
        true ->
            %% Single ASCII octet. In `full` mode a reserved char is preserved
            %% verbatim as its ORIGINAL escape (original case), else emitted raw.
            case Mode =:= full andalso uri_reserved(B1) of
                true ->
                    <<H1, H2, _/binary>> = Rest,
                    uri_decode(R1, Mode, <<Acc/binary, $%, H1, H2>>);
                false ->
                    uri_decode(R1, Mode, <<Acc/binary, B1>>)
            end;
        false ->
            %% Multi-octet UTF-8 lead: gather the continuation escapes, validate,
            %% and emit the decoded code point (always > U+007F, never reserved).
            N = uri_leadlen(B1),
            {CP, R2} = uri_conts(N - 1, R1, [B1]),
            uri_decode(R2, Mode, <<Acc/binary, CP/utf8>>)
    end;
uri_decode(<<C, Rest/binary>>, Mode, Acc) ->
    uri_decode(Rest, Mode, <<Acc/binary, C>>).

%% Read exactly two hex digits off the front of `Bin`; return {Byte, Rest}.
%% Fewer than two remaining chars, or a non-hex digit, is a URIError.
uri_hexbyte(<<H1, H2, Rest/binary>>) ->
    case {uri_hexval(H1), uri_hexval(H2)} of
        {D1, D2} when is_integer(D1), is_integer(D2) -> {D1 * 16 + D2, Rest};
        _ -> uri_error()
    end;
uri_hexbyte(_) ->
    uri_error().

uri_hexval(C) when C >= $0, C =< $9 -> C - $0;
uri_hexval(C) when C >= $A, C =< $F -> C - $A + 10;
uri_hexval(C) when C >= $a, C =< $f -> C - $a + 10;
uri_hexval(_) -> error.

%% Number of octets in a UTF-8 sequence given its lead byte (2..4). A
%% continuation byte (10xxxxxx) or a 5+-octet lead (11111xxx) as a lead is a
%% URIError.
uri_leadlen(B) when B >= 16#C0, B =< 16#DF -> 2;
uri_leadlen(B) when B >= 16#E0, B =< 16#EF -> 3;
uri_leadlen(B) when B >= 16#F0, B =< 16#F7 -> 4;
uri_leadlen(_) -> uri_error().

%% Read `K` further `%XX` continuation escapes onto the octet accumulator
%% (reversed), then decode + range-validate the full sequence. Each continuation
%% must be a `%`-escape of a 10xxxxxx byte; anything else is a URIError.
uri_conts(0, Bin, Acc) ->
    {uri_codepoint(lists:reverse(Acc)), Bin};
uri_conts(K, <<$%, Bin/binary>>, Acc) ->
    {B, Rest} = uri_hexbyte(Bin),
    case B band 16#C0 =:= 16#80 of
        true -> uri_conts(K - 1, Rest, [B | Acc]);
        false -> uri_error()
    end;
uri_conts(_, _, _) ->
    uri_error().

%% Assemble a Unicode code point from its 2/3/4 UTF-8 octets, rejecting overlong
%% encodings, UTF-16 surrogates, and values above U+10FFFF (RFC 3629). Returns
%% the code point, or raises a URIError.
uri_codepoint([B1, B2]) ->
    CP = ((B1 band 16#1F) bsl 6) bor (B2 band 16#3F),
    case CP >= 16#80 of
        true -> CP;
        false -> uri_error()
    end;
uri_codepoint([B1, B2, B3]) ->
    CP =
        ((B1 band 16#0F) bsl 12) bor ((B2 band 16#3F) bsl 6) bor
            (B3 band 16#3F),
    case CP >= 16#800 andalso not (CP >= 16#D800 andalso CP =< 16#DFFF) of
        true -> CP;
        false -> uri_error()
    end;
uri_codepoint([B1, B2, B3, B4]) ->
    CP =
        ((B1 band 16#07) bsl 18) bor ((B2 band 16#3F) bsl 12) bor
            ((B3 band 16#3F) bsl 6) bor (B4 band 16#3F),
    case CP >= 16#10000 andalso CP =< 16#10FFFF of
        true -> CP;
        false -> uri_error()
    end.

%% A JS URIError (§19.2.6.5): a malformed %-escape or invalid UTF-8 octet run.
uri_error() -> erlang:error({js_error, uri_error, <<"URI malformed">>}).

%% Number.isNaN / Number.isFinite — NO coercion (only actual numbers qualify).
number_is_nan(js_nan) -> true;
number_is_nan(_) -> false.

number_is_finite(X) when is_integer(X); is_float(X) -> true;
number_is_finite(_) -> false.

number_is_integer(X) when is_integer(X) -> true;
number_is_integer(X) when is_float(X) -> X == trunc(X);
number_is_integer(_) -> false.

%% Number.isSafeInteger — like Number.isInteger (NO coercion; only real numbers
%% qualify) but additionally bounded to the safe-integer range |x| ≤ 2^53 − 1
%% (9007199254740991), so 2^53 itself and the infinities/NaN are all false.
number_is_safe_integer(X) when is_integer(X) ->
    abs(X) =< 9007199254740991;
number_is_safe_integer(X) when is_float(X) ->
    X == trunc(X) andalso abs(X) =< 9007199254740991.0;
number_is_safe_integer(_) ->
    false.

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

%% JSON.stringify(value, replacer, space) — a JSON binary, or `undefined` when the
%% root value serializes to nothing (undefined / a function / a symbol).
%%
%% `replacer` follows the spec (sec-json.stringify):
%%   * a callable replacer is applied to every (key, value) pair and its result is
%%     serialized in place;
%%   * an Array replacer is a PropertyList — the ONLY keys emitted for objects, in
%%     the array's order (String/Number entries only; duplicates and other types
%%     ignored);
%%   * anything else is treated as no replacer.
%% `space` sets the indentation gap: a Number N yields min(10, floor(N)) spaces
%% (0/negative → none); a String yields its first 10 code units; else none.
%% Deviation: `this`-bound `toJSON`/replacer receivers and String/Number/Boolean
%% wrapper objects are not modelled (this runtime has no such wrappers).
json_stringify(V, Replacer, Space) ->
    {RepFn, PropList} = json_replacer(Replacer),
    Gap = json_gap(Space),
    St = {RepFn, PropList, Gap},
    %% SerializeJSONProperty(the empty String, {"": value}).
    case json_serialize_prop(<<"">>, {root, V}, St, <<"">>) of
        skip -> undefined;
        Io -> iolist_to_binary(Io)
    end.

%% Split the replacer argument into {ReplacerFunction, PropertyList}. Exactly one
%% is non-`undefined` (a callable replacer OR an Array); other values → both
%% `undefined` (no filtering, no transform).
json_replacer(R) when is_function(R) -> {R, undefined};
json_replacer(R) when is_reference(R) ->
    case erlang:get(?CELL_KEY(R)) of
        {js_array, Len, Map} -> {undefined, json_proplist(arr_list(Len, Map))};
        _ -> {undefined, undefined}
    end;
json_replacer(_) -> {undefined, undefined}.

%% Build the PropertyList from an Array replacer's elements: keep String and
%% Number entries (Numbers via ToString), skip everything else, and drop
%% duplicates while preserving first-seen order (sec-json.stringify step 5.b).
json_proplist(Elems) ->
    lists:foldl(
        fun(V, Acc) ->
            case json_prop_item(V) of
                undefined ->
                    Acc;
                Item ->
                    case lists:member(Item, Acc) of
                        true -> Acc;
                        false -> Acc ++ [Item]
                    end
            end
        end,
        [],
        Elems
    ).

json_prop_item(V) when is_binary(V) -> V;
json_prop_item(V) when is_integer(V) -> integer_to_binary(V);
json_prop_item(V) when is_float(V) -> to_string(V);
json_prop_item(js_nan) -> <<"NaN">>;
json_prop_item(js_inf) -> <<"Infinity">>;
json_prop_item(js_neg_inf) -> <<"-Infinity">>;
json_prop_item(_) -> undefined.

%% The indentation gap for `space`. Numbers clamp to [0,10] spaces (floor toward
%% zero); Strings contribute their first 10 code units; other types → no gap.
json_gap(N) when is_integer(N) -> json_gap_spaces(N);
json_gap(N) when is_float(N) -> json_gap_spaces(trunc(N));
json_gap(js_inf) -> binary:copy(<<" ">>, 10);
json_gap(js_neg_inf) -> <<>>;
json_gap(js_nan) -> <<>>;
json_gap(S) when is_binary(S) -> from_cps(lists:sublist(cps(S), 10));
json_gap(_) -> <<>>.

json_gap_spaces(N) when N >= 1 -> binary:copy(<<" ">>, min(10, N));
json_gap_spaces(_) -> <<>>.

%% SerializeJSONProperty(key, holder): read holder[key] (invoking any getter), let
%% a callable `toJSON` and the replacer function transform it, then serialize by
%% type. Returns an iolist, or `skip` when the value produces no JSON text.
json_serialize_prop(Key, Holder, {RepFn, _, _} = St, Indent) ->
    Value0 = json_get(Holder, Key),
    Value1 = json_apply_tojson(Key, Value0),
    Value2 =
        case RepFn of
            undefined -> Value1;
            _ -> call_cb(RepFn, [Key, Value1])
        end,
    json_serialize_value(Value2, St, Indent).

%% Get(holder, key). The root holder is the synthetic wrapper {"": value}; every
%% other holder is a live object/array cell, so getters and deletions observed
%% mid-serialization are honoured.
json_get({root, V}, _Key) -> V;
json_get(Holder, Key) -> get_prop(Holder, Key).

%% If `value` is an object exposing a callable own `toJSON`, replace it with
%% `toJSON(key)`; otherwise leave it unchanged (sec-serializejsonproperty step 2).
json_apply_tojson(Key, V) when is_reference(V) ->
    case erlang:get(?CELL_KEY(V)) of
        M when is_map(M) ->
            case resolve_get(maps:get(<<"toJSON">>, M, undefined)) of
                Fn when is_function(Fn) -> call_cb(Fn, [Key]);
                _ -> V
            end;
        _ ->
            V
    end;
json_apply_tojson(_Key, V) ->
    V.

json_serialize_value(V, St, Indent) ->
    case js_type(V) of
        number -> json_num(V);
        boolean -> to_string(V);
        string -> json_str(V);
        null -> <<"null">>;
        undefined -> skip;
        function -> skip;
        object -> json_serialize_cell(V, St, Indent);
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

%% Serialize an object/array cell. Arrays and plain objects recurse; every other
%% cell kind (regex, Map, Set, …) has no enumerable own properties and renders as
%% an empty object `{}`, matching JSON.stringify on an ordinary object.
json_serialize_cell(Ref, St, Indent) ->
    case erlang:get(?CELL_KEY(Ref)) of
        {js_array, Len, _Map} -> json_serialize_array(Ref, Len, St, Indent);
        M when is_map(M) -> json_serialize_object(Ref, M, St, Indent);
        _ -> <<"{}">>
    end.

%% SerializeJSONArray: each index is serialized via SerializeJSONProperty (so the
%% replacer/toJSON run per element); an element that produces no text becomes
%% `null`. With a gap, elements are placed one per line indented one level deeper.
json_serialize_array(_Ref, 0, _St, _Indent) ->
    <<"[]">>;
json_serialize_array(Ref, Len, {_, _, Gap} = St, Indent) ->
    Indent2 = <<Indent/binary, Gap/binary>>,
    Elems = [json_array_elem(Ref, I, St, Indent2) || I <- lists:seq(0, Len - 1)],
    json_wrap($[, $], Elems, Gap, Indent, Indent2).

json_array_elem(Ref, I, St, Indent2) ->
    case json_serialize_prop(integer_to_binary(I), Ref, St, Indent2) of
        skip -> <<"null">>;
        Io -> Io
    end.

%% SerializeJSONObject. The key set is the replacer's PropertyList when present,
%% otherwise the object's own enumerable string keys. Each key is serialized via
%% SerializeJSONProperty (re-reading holder[key], so a getter that mutates a
%% sibling is observed); keys producing no text are omitted.
json_serialize_object(Ref, M, {_, PropList, Gap} = St, Indent) ->
    Keys =
        case PropList of
            undefined -> [K || {K, _} <- maps:to_list(M)];
            _ -> PropList
        end,
    Indent2 = <<Indent/binary, Gap/binary>>,
    Colon =
        case Gap of
            <<>> -> $:;
            _ -> <<": ">>
        end,
    Members = json_object_members(Ref, Keys, St, Indent2, Colon),
    json_wrap(${, $}, Members, Gap, Indent, Indent2).

json_object_members(_Ref, [], _St, _Indent2, _Colon) ->
    [];
json_object_members(Ref, [K | Ks], St, Indent2, Colon) ->
    case json_serialize_prop(K, Ref, St, Indent2) of
        skip ->
            json_object_members(Ref, Ks, St, Indent2, Colon);
        Io ->
            [
                [json_str(K), Colon, Io]
                | json_object_members(Ref, Ks, St, Indent2, Colon)
            ]
    end.

%% Wrap the serialized members between `Open`/`Close`. Without a gap the members
%% are comma-joined on one line; with a gap each sits on its own line indented by
%% `Indent2`, and the close bracket returns to `Indent`. An empty collection is
%% always the bare `Open Close` pair.
json_wrap(Open, Close, [], _Gap, _Indent, _Indent2) ->
    [Open, Close];
json_wrap(Open, Close, Members, <<>>, _Indent, _Indent2) ->
    [Open, lists:join($,, Members), Close];
json_wrap(Open, Close, Members, _Gap, Indent, Indent2) ->
    Sep = [$,, $\n, Indent2],
    [Open, $\n, Indent2, lists:join(Sep, Members), $\n, Indent, Close].

%% JSON.parse(str) — parse JSON text to JS terms (numbers, binaries, true/false/null,
%% arrays, objects). The argument is first coerced with ToString (per
%% sec-json.parse step 1), so a non-string is stringified before parsing.
%% Malformed input is a type_error.
json_parse(Str) ->
    Bin = json_text(Str),
    case json_val(json_ws(Bin)) of
        {ok, V, Rest} ->
            case json_ws(Rest) of
                <<>> -> V;
                _ -> type_error(Str)
            end;
        error ->
            type_error(Str)
    end.

%% ToString for JSON.parse's `text` argument. Strings pass through; an object is
%% run through ToPrimitive with the string hint (a callable own `toString`, else
%% `valueOf`, supplies the primitive) before being stringified; everything else
%% uses the ordinary numeric/boolean/etc. ToString.
json_text(V) when is_binary(V) ->
    V;
json_text(V) when is_reference(V) ->
    case erlang:get(?CELL_KEY(V)) of
        M when is_map(M) ->
            to_string(json_to_primitive(M, [<<"toString">>, <<"valueOf">>], V));
        _ ->
            to_string(V)
    end;
json_text(V) ->
    to_string(V).

%% Walk the preferred method names in order; the first that is callable and
%% returns a non-object value wins. If none qualifies, fall back to `V` itself
%% (which ToString renders as "[object Object]").
json_to_primitive(_M, [], V) ->
    V;
json_to_primitive(M, [Name | Rest], V) ->
    case resolve_get(maps:get(Name, M, undefined)) of
        Fn when is_function(Fn) ->
            R = call_cb(Fn, []),
            case js_type(R) of
                object -> json_to_primitive(M, Rest, V);
                _ -> R
            end;
        _ ->
            json_to_primitive(M, Rest, V)
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
