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
    new_object/0, get_prop/2, set_prop/3, has_prop/2,
    new_array/1, array_push/2, array_pop/1, is_array/1,
    array_map/2, array_filter/2, array_foreach/2, array_reduce/3,
    array_reduce1/2, array_some/2, array_every/2, array_find/2,
    array_find_index/2, array_index_of/2, array_includes/2, array_join/2,
    array_slice/3, array_concat/2, array_reverse/1, array_shift/1,
    array_unshift/2, array_sort/2,
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

%% ── array value methods ──────────────────────────────────

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

%% concat(...items) — spreads array items, appends others as single elements.
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
