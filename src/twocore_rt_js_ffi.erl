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
    new_object/0, globalthis_new/0, wrapper_new/2, error_make/2, error_ctor/1, error_is_error/1, js_error_to_value/1, gen_make/1, gen_next/2, gen_return/2, iter_array/1, iter_to_array/1, iter_take/2, iter_drop/2, get_prop/2, set_prop/3, define_data/3, define_accessor/4,
    builtin_ctor/1, builtin_prototype/1, to_object/1,
    static_get/2, static_get_chain/2, static_set/3, has_prop/2, delete_prop/2,
    new_array/1, array_construct/1, array_push/2, array_pop/1, is_array/1, array_spread_into/2,
    array_from/1, array_from_map/2, array_flat/2, array_fill/4, array_copy_within/4, array_splice/2, array_at/2, array_proto_fn/1,
    apply_fn/2, func_call/2, func_apply/2, func_bind/2, fit_list/2, array_to_list/1, apply_arg_list/1,
    str_pad_start/3, str_pad_end/3, string_from_char_code/1,
    string_from_code_point/1, string_raw/2, date_now/0,
    date_new/1, date_utc/1, date_parse/1, date_call/3,
    array_flat_map/2, array_find_last/2, array_find_last_index/2,
    array_last_index_of/3, array_last_index_of_end/2,
    num_to_fixed/2, num_to_exponential/2, num_to_precision/2,
    to_string_dispatch/1, num_to_string_radix/2,
    new_regex/2, regex_construct/2, regex_test/2, regex_exec/2, regex_source/1,
    regex_flags/1,
    str_match/2, str_search/2,
    new_map/1, new_set/1, js_m_set/2, js_m_get/2, js_m_add/2, js_m_has/2,
    js_m_delete/2, js_m_clear/2, js_m_foreach/2, map_group_by/2,
    js_m_get_or_insert/2, js_m_get_or_insert_computed/2,
    js_m_keys/2, js_m_values/2, js_m_entries/2,
    new_weakset/1, weakset_ctor/0, weakset_no_new/0,
    set_union/2, set_intersection/2, set_difference/2,
    set_symmetric_difference/2, set_is_disjoint_from/2,
    set_is_subset_of/2, set_is_superset_of/2,
    new_weakmap/1, weakmap_ctor/0,
    array_map/2, array_filter/2, array_foreach/2, array_reduce/3,
    array_reduce1/2, array_reduce_right/3, array_reduce_right1/2,
    array_some/2, array_every/2, array_find/2, array_includes/3,
    array_find_index/2, array_index_of/3, array_join/2,
    array_slice/3, array_concat/2, array_reverse/1, array_shift/1,
    array_unshift/2, array_sort/2,
    array_to_reversed/1, array_to_sorted/2, array_with/3, array_to_spliced/2,
    str_char_at/2, str_char_code_at/2, str_code_point_at/2, str_normalize/2,
    str_upper/1, str_lower/1,
    str_substring/3, str_split/3, str_trim/1, str_trim_start/1,
    str_trim_end/1, str_repeat/2, str_starts_with/3, str_ends_with/3,
    str_replace/3, str_replace_all/3,
    str_is_well_formed/1, str_to_well_formed/1, str_locale_compare/2,
    str_proto_fn/1,
    parse_int/2, parse_float/1, is_nan/1, is_finite/1, is_nullish/1,
    number_is_nan/1, number_is_finite/1, number_is_integer/1,
    number_is_safe_integer/1,
    object_keys/1, object_values/1, object_entries/1, object_assign_into/2,
    object_rest/2, object_freeze/1, object_is_frozen/1,
    object_prevent_extensions/1, object_is_extensible/1,
    object_seal/1, object_is_sealed/1,
    object_from_entries/1, object_is/2, object_has_own/2,
    reflect_has/2, reflect_get/2, reflect_set/4, reflect_delete_property/2,
    reflect_own_keys/1, reflect_get_prototype_of/1, reflect_is_extensible/1,
    reflect_prevent_extensions/1, reflect_apply/3,
    json_stringify/3, json_parse/1,
    encode_uri_component/1, encode_uri/1,
    decode_uri_component/1, decode_uri/1,
    global_escape/1, global_unescape/1,
    empty_list/0, console_log/1, not_callable/1,
    symbol_make/1, symbol_ctor/0, symbol_no_new/0, symbol_wellknown/1,
    symbol_for/1, symbol_key_for/1
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
%% a Symbol value: a `{js_symbol, Id, Desc}` tuple (Id unique — user symbols use a
%% process-unique integer, well-known symbols a `{wk, Name}` tag). Structural tuple
%% equality gives Symbol identity for free in `strict_eq`.
js_type({js_symbol, _, _}) -> symbol;
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

%% Sign-preserving zero for the rounding functions (floor/ceil/round/trunc).
%% Per each Math.* spec table, a zero result inherits the IEEE sign of the
%% ORIGINAL argument: Math.ceil(-0.5), Math.trunc(-0.9) and Math.round(-0.3)
%% all yield -0, as do the operations applied to -0 itself. A non-zero result
%% (an Erlang integer) passes straight through; only the exact-zero case is
%% rewritten to +0.0 / -0.0 by the argument's sign bit.
signed_int_result(0, Orig) -> signed_zero(zero_aware_sign(as_float(Orig)));
signed_int_result(R, _Orig) -> R.

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
%% A zero must negate to the OTHER signed zero: -(+0) is IEEE -0.0 and -(-0.0) is
%% +0.0 (§6.1.6.1.1 / unary `-`). Erlang integer negation of 0 yields the integer
%% +0 (the BEAM has no integer -0), which would silently drop the sign bit that
%% Object.is, `1 / -0`, and Math rounding observe. Routing any zero through a
%% float multiply carries the sign correctly for all three cases.
nneg(N) when N == 0 -> N * -1.0;
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
%% base −∞ with a negative exponent: an odd-integer exponent yields −0, every
%% other (even or fractional) negative exponent yields +0
%% (sec-numeric-types-number-exponentiate).
npow(neg_inf, Exp) ->
    case is_odd_int(Exp) of
        true -> -0.0;
        false -> 0
    end;
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
%% Sign-of-zero preservation. Every unary Math function whose spec table maps a
%% zero argument to a zero result preserves the IEEE sign of that zero — e.g.
%% Math.sign(-0), Math.cbrt(-0), Math.expm1(-0), Math.log1p(-0), Math.sin(-0)
%% all return -0. Math.abs is the sole exception (abs(-0) = +0), so it is
%% excluded here and handled by its own finite clause. Only a float ±0.0
%% argument needs this rewrite; integer 0 is already +0.
munary(abs, N) -> munary_finite(abs, N);
munary(Method, N) when is_float(N), N == 0.0 ->
    case munary_finite(Method, N) of
        R when R == 0 -> signed_zero(zero_aware_sign(N));
        R -> R
    end;
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

munary_finite(floor, N) -> signed_int_result(floor(as_float(N)), N);
munary_finite(ceil, N) -> signed_int_result(ceil(as_float(N)), N);
%% JS Math.round is round-half-toward-+Infinity. The naive floor(x + 0.5) is
%% NOT equivalent: for the largest double below 0.5 (0.49999999999999994) the
%% sum rounds up to 1.0, giving 1 instead of 0. Compare the fraction directly:
%% frac >= 0.5 rounds up (ties to +Infinity), otherwise down.
munary_finite(round, N) ->
    F = as_float(N),
    Fl = floor(F),
    R =
        case F - Fl >= 0.5 of
            true -> Fl + 1;
            false -> Fl
        end,
    signed_int_result(R, N);
munary_finite(trunc, N) -> signed_int_result(trunc(as_float(N)), N);
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
%% Per sec-math.min, the comparison treats +0 as larger than -0, so a tie
%% between zeros resolves to -0 whenever either operand is -0 (Erlang `=<`
%% considers -0.0 and 0.0 equal and would otherwise leak the wrong sign).
mmin(A, B) when A == 0, B == 0 -> signed_zero(minus_zero_sign(is_neg_zero(A) orelse is_neg_zero(B)));
mmin(A, B) when A =< B -> A;
mmin(_, B) -> B.

mmax(neg_inf, B) -> B;
mmax(A, neg_inf) -> A;
mmax(inf, _) -> inf;
mmax(_, inf) -> inf;
%% Per sec-math.max, +0 is larger than -0: a tie between zeros resolves to +0
%% unless BOTH operands are -0.
mmax(A, B) when A == 0, B == 0 -> signed_zero(minus_zero_sign(is_neg_zero(A) andalso is_neg_zero(B)));
mmax(A, B) when A >= B -> A;
mmax(_, B) -> B.

%% Map a "this zero is negative" boolean to a sign argument for signed_zero/1
%% (true → -1 → -0.0, false → +1 → +0.0).
minus_zero_sign(true) -> -1;
minus_zero_sign(false) -> 1.

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
        %% an error stringifies per Error.prototype.toString (§20.5.3.4).
        {js_err, Name, Msg} -> error_to_string(Name, Msg);
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
        symbol -> <<"symbol">>;
        other -> <<"object">>
    end.

%% ───────────────────────── string → number ─────────────────────────

%% JS Number(string): trimmed; "" → 0; "±Infinity" → ±inf; decimal integer or
%% float, with the JS-legal-but-Erlang-illegal shapes (".5", "5.", "1e3")
%% normalized before binary_to_float. Radix prefixes ("0x10") → NaN (header
%% divergence note).
str_to_num(Bin) ->
    T = unicode:characters_to_binary(string:trim(Bin, both, ?JS_WS)),
    V =
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
        end,
    %% Per §9.3.1: the MV of `StrDecimalLiteral ::: - StrUnsignedDecimalLiteral` is
    %% the negation of the unsigned MV, and the negation of 0 is -0. So a leading
    %% "-" on a zero magnitude (e.g. "-0", "-0.0", "-0e5") yields negative zero.
    case T of
        <<"-", _/binary>> when V == 0 -> -0.0;
        _ -> V
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

%% The `globalThis` value (§19.3.1): THE global object, obtained as a stable
%% per-instance SINGLETON so that every evaluation of the `globalThis` identifier
%% (and top-level `this`) yields the SAME reference. Identity matters — the spec
%% requires `globalThis === globalThis` and `globalThis.globalThis === globalThis`,
%% which only holds if a single cell backs every access. Being a cell it is
%% `typeof` "object" (never null). The singleton is memoised in this process's
%% dictionary under a fixed key (namespaced so it cannot collide with a `?CELL_KEY`
%% ref key or an instance key), created lazily on first reference. A full mutable
%% global-object property model is out of scope: property reads such as
%% `globalThis.Array` are resolved by the lowerer against the already-bound globals,
%% not stored in this cell's map.
globalthis_new() ->
    case erlang:get(js_globalthis_singleton) of
        undefined ->
            Ref = cell_new(#{}),
            erlang:put(js_globalthis_singleton, Ref),
            Ref;
        Ref ->
            Ref
    end.

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

%% The constructor NAME (binary) for a primitive-wrapper kind, used to resolve a
%% wrapper's `.constructor` to the matching built-in constructor VALUE.
wrapper_ctor_name(number) -> <<"Number">>;
wrapper_ctor_name(string) -> <<"String">>;
wrapper_ctor_name(boolean) -> <<"Boolean">>.

%% ─────────────── built-in constructors as first-class values ───────────────
%% A built-in constructor (`Array`, `Object`, `String`, `Number`, `Boolean`,
%% `Function`, `RegExp`, `Date`, `Map`, `Set`) as a first-class fun VALUE, so a
%% BARE `Array` reference has `typeof` "function" and can be assigned / passed as
%% an argument. The fun closes over the (binary) constructor `Name`, so two
%% references to the SAME constructor are fun-identical under `=:=` — this is what
%% makes `Array === Array` and `[].constructor === Array` hold by identity.
%%
%% The direct `Array(...)` / `new Array(...)` / `Array.method(...)` forms are all
%% lowered structurally by the frontend and NEVER reach this fun; it is applied
%% only when the constructor is used as a stored/callback VALUE (through
%% `call_cb`, which fits the single argument). Applied, it performs the
%% call-without-`new` coercion (`builtin_ctor_apply/2`).
builtin_ctor(Name) ->
    N = to_string(Name),
    fun(X) -> builtin_ctor_apply(N, X) end.

%% The call-WITHOUT-`new` behaviour of a built-in constructor VALUE applied to a
%% single argument (the arity `call_cb` fits it to). Each mirrors the spec's
%% call form where cheap: `Array(x)` builds an array (a single Number is a
%% length), `String`/`Number`/`Boolean` coerce, `RegExp` compiles. `Object(x)`
%% is ToObject-ish: an object flows through unchanged, `undefined`/`null` yield a
%% fresh object, and a primitive is returned as-is (no wrapper boxing in v1).
%% `Map`/`Set` require `new` (a plain call is a TypeError, per §24.1.1.1 /
%% §24.2.1.1). `Function` stays an ahead-of-time boundary. `Date()` renders the
%% current instant as a string (§21.4.2.1 step 1).
builtin_ctor_apply(<<"Array">>, X) -> array_construct([X]);
builtin_ctor_apply(<<"Object">>, X) -> to_object(X);
builtin_ctor_apply(<<"String">>, X) -> to_string(X);
builtin_ctor_apply(<<"Number">>, X) -> to_number(X);
builtin_ctor_apply(<<"Boolean">>, X) -> case truthy(X) of 1 -> true; _ -> false end;
builtin_ctor_apply(<<"RegExp">>, X) -> regex_construct(X, undefined);
builtin_ctor_apply(<<"Date">>, _X) -> date_to_string(date_now());
builtin_ctor_apply(<<"Map">>, _X) -> type_error(<<"Constructor Map requires 'new'">>);
builtin_ctor_apply(<<"Set">>, _X) -> type_error(<<"Constructor Set requires 'new'">>);
builtin_ctor_apply(<<"Function">>, _X) ->
    type_error(<<"Function constructor is not supported (ahead-of-time compiler)">>);
builtin_ctor_apply(_Name, X) -> X.

%% ToObject-ish for the `Object(x)` call form: an existing object (a cell) flows
%% through unchanged; `undefined`/`null` yield a fresh empty object (§20.1.1.1
%% step 2); a primitive is returned as-is (a full wrapper object is out of scope).
to_object(undefined) -> new_object();
to_object(null) -> new_object();
to_object(X) when is_reference(X) -> X;
to_object(X) -> X.

%% A built-in constructor's `.prototype` as a STABLE per-constructor marker cell,
%% memoised in the process dictionary under a fixed `{js_builtin_prototype, Name}`
%% key so `Array.prototype === Array.prototype` holds by reference identity (and
%% `Array.prototype !== Object.prototype`). It is NOT a real prototype object — it
%% carries no methods. `X.prototype.<method>` is routed to the dedicated proto-fn
%% ops by the frontend BEFORE this, so this backs only the bare `X.prototype`
%% value (identity, `typeof` "object").
builtin_prototype(Name) ->
    N = to_string(Name),
    Key = {js_builtin_prototype, N},
    case erlang:get(Key) of
        undefined ->
            Ref = cell_new(#{}),
            erlang:put(Key, Ref),
            Ref;
        Ref ->
            Ref
    end.

%% ───────────────────────── error objects ─────────────────────────
%% A JS error VALUE (from `new TypeError(m)` / `TypeError(m)`) is a cell holding
%% `{js_err, Name, Message}` — both binaries. It is a JS-level value that flows
%% through variables, `throw`, and try/catch like any object. This is DELIBERATELY
%% a different tag from the runtime's INTERNAL `erlang:error({js_error, Kind, Detail})`
%% convention (that one is a raised Erlang exception used to signal bad primitive
%% ops — never a JS value), so the two mechanisms never collide.
%%
%% v1 scope: readable `.name` / `.message`, a spec `toString`, `instanceof` against
%% the seven bound constructor globals, and throwability. NO real prototype chain,
%% `.stack`, `cause`, or Error subclassing.

%% `new Name(msg)` / `Name(msg)` — construct the error value. `Name` is the binary
%% constructor name ("TypeError", "Error", …); `MsgArg` is the raw first argument
%% (or the atom `undefined` when the constructor was called with no argument). Per
%% §20.5.1.1 / §19.5.1.1 an `undefined` message is NOT installed, so `.message`
%% reads the prototype's "" default; any other argument is ToString'd.
error_make(Name, MsgArg) ->
    cell_new({js_err, to_string(Name), error_message([MsgArg])}).

%% An error constructor as a first-class fun VALUE, so a BARE `TypeError` reference
%% has `typeof` "function" and, if applied through a closure call site, constructs
%% an error. Fixed arity 1 (the NativeError `length` is 1); the common uses — the
%% dedicated call/`new` lowering and being passed as an (ignored) argument to the
%% test harness's `assertThrows` — do not depend on this fun's arity.
error_ctor(Name) ->
    N = to_string(Name),
    fun(Msg) -> cell_new({js_err, N, error_message([Msg])}) end.

%% Error.isError(v) → 1|0 (§20.5.2.1). Returns 1 only when `v` is a genuine Error
%% VALUE — a cell holding `{js_err, Name, Msg}`, i.e. an object with an [[ErrorData]]
%% internal slot (what `new Error`/`new TypeError`/… and a caught engine error
%% produce). Every other value — a primitive (number, string, boolean, undefined,
%% null, symbol) or an ordinary object merely SHAPED like an error (a plain object
%% with `name`/`message`/`stack` own properties, a "fake error") — yields 0, because
%% the slot, not the shape, is what the predicate tests.
error_is_error(Recv) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_err, _, _} -> 1;
        _ -> 0
    end;
error_is_error(_) ->
    0.

%% js_error_to_value(Reason) -> {ok, [ErrCell]} | {error, nil}
%% Classify a caught BEAM error `Reason` for a JS `try`/`catch` and, when it is the
%% runtime's INTERNAL engine-error convention `{js_error, Kind, Detail}` (raised by
%% `type_error/1`, `range_error/1`, `not_callable/1`, `uri_error/0`, …), CONVERT it to
%% a JS-level error VALUE so the `catch` binding behaves per ECMAScript. The value is a
%% fresh `{js_err, Name, Message}` cell (the same shape `new TypeError(m)` produces), so
%% the bound `e` answers `.name` / `.message` and `e instanceof TypeError` correctly.
%%
%% The 1-element list return mirrors `twocore_rt_exn_ffi:match_tag/2`'s `{ok, Payload}`
%% wire shape (Payload a list), so the emitter binds the single catch parameter with the
%% SAME `[E]` list pattern it uses for an explicit `throw`.
%%
%% Any OTHER `Reason` — a `{wasm_exn, _, _}` (an explicit JS `throw`, already handled by
%% `match_tag` upstream), a `{wasm_trap, _}` trap / fuel raise, an `exit`, or an arbitrary
%% BEAM error — yields `{error, nil}` so the caller RE-RAISES it. That is what keeps traps
%% and must-propagate signals escaping the `try` (ECMAScript catches Errors, not host
%% aborts) and keeps an explicit throw bound AS-IS rather than rewrapped.
js_error_to_value({js_error, Kind, Detail}) ->
    Name = js_error_kind_name(Kind),
    Msg = js_error_kind_message(Kind, Detail),
    {ok, [cell_new({js_err, Name, Msg})]};
js_error_to_value({badfun, _Target}) ->
    %% A native `apply` of a non-function VALUE — the direct-call lowering of `x()` when
    %% `x` is not callable (a number, object, undefined, …). ECMAScript §13.3.6.1 makes
    %% this a TypeError ("x is not a function"). `{badfun, _}` is the EXACT BEAM reason
    %% `erlang:apply` raises for a non-fun; it is a JS-operation consequence, not a host
    %% abort, so a JS `try`/`catch` must catch it. (Matched by shape, narrowly — a
    %% `{badarity, _}` wrong-arity apply is deliberately NOT matched.)
    {ok, [cell_new({js_err, <<"TypeError">>, <<"is not a function">>})]};
js_error_to_value(_) ->
    {error, nil}.

%% Map an internal engine-error Kind atom to its ECMAScript constructor name (the binary
%% stored as `.name`, and matched by `instanceof`). Every Kind the runtime raises today
%% (`type_error` / `range_error` / `uri_error`) has a dedicated NativeError; any future or
%% unknown Kind degrades to the base `Error`.
js_error_kind_name(type_error) -> <<"TypeError">>;
js_error_kind_name(range_error) -> <<"RangeError">>;
js_error_kind_name(uri_error) -> <<"URIError">>;
js_error_kind_name(_) -> <<"Error">>.

%% The `.message` for a converted engine error. `range_error`/`uri_error` already carry a
%% descriptive binary `Detail` (e.g. "Invalid array length"), so it is used verbatim. A
%% `type_error`'s `Detail` is the offending VALUE (a `not_callable` target, a bad receiver),
%% which has no faithful short rendering, so a fixed spec-flavoured message is used; a binary
%% `Detail` (should one arise) passes through.
js_error_kind_message(_Kind, Detail) when is_binary(Detail) -> Detail;
js_error_kind_message(type_error, _Detail) -> <<"not an object or not callable">>;
js_error_kind_message(range_error, _Detail) -> <<"value out of range">>;
js_error_kind_message(uri_error, _Detail) -> <<"URI malformed">>;
js_error_kind_message(_Kind, _Detail) -> <<>>.

%% The `message` string for an error: an absent or `undefined` argument yields ""
%% (the prototype default), otherwise ToString of the argument.
error_message([]) -> <<>>;
error_message([undefined | _]) -> <<>>;
error_message([Arg | _]) -> to_string(Arg).

%% Error.prototype.toString (§20.5.3.4 / §19.5.3.4): the name alone when the message
%% is empty, the message alone when the name is empty, else "name: message". Both
%% arguments are already-ToString'd binaries.
error_to_string(Name, <<>>) -> Name;
error_to_string(<<>>, Msg) -> Msg;
error_to_string(Name, Msg) -> <<Name/binary, ": ", Msg/binary>>.

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
        %% A Set iterates its elements in insertion order (its default iterator is
        %% Set.prototype.values, §24.2.3.10).
        {js_set, _, _} -> new_array(set_elems(X));
        %% A Map iterates its `[key, value]` entries in insertion order (its default
        %% iterator is Map.prototype.entries, §24.1.3.12).
        {js_map, _, _} -> new_array(map_entry_arrays(X));
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
        {js_gen, StepFn} ->
            %% Mark the generator RUNNING while its step executes so a re-entrant
            %% `.next()` (a step that resumes its own generator) is rejected with a
            %% TypeError — the "generator is already running" state (§27.5.3.3).
            %% Restored to suspended afterwards (even on an exception) unless the
            %% step CLOSED the generator in the meantime.
            erlang:put(?CELL_KEY(Recv), {js_gen_running, StepFn}),
            try
                call_cb(StepFn, [arg(Args, 0)])
            after
                case erlang:get(?CELL_KEY(Recv)) of
                    {js_gen_running, _} ->
                        erlang:put(?CELL_KEY(Recv), {js_gen, StepFn});
                    _ ->
                        ok
                end
            end;
        {js_gen_running, _} ->
            type_error(<<"Generator is already running">>);
        js_gen_done ->
            iter_result(undefined, true);
        _ ->
            delegate(Recv, <<"next">>, Args)
    end;
gen_next(Recv, Args) ->
    delegate(Recv, <<"next">>, Args).

%% `gen.return(v)` — Generator.prototype.return (§27.5.1.4). Closes the generator
%% (as if a `return v` ran at the current suspend point) and returns the result
%% object `{value: v, done: true}`; `v` defaults to `undefined`. A subsequent
%% `.next()`/iterator-helper on the closed generator then sees it exhausted. The
%% generators modelled here have no observable `try`/`finally`, so closing is a
%% simple state transition to DONE. A non-generator receiver delegates to a user
%% `return` method (a plain-object iterator implementing the optional return step);
%% a receiver without one is a non-reference/absent-method — left to `delegate`.
gen_return(Recv, Args) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        Tag when
            Tag =:= js_gen_done orelse
                (is_tuple(Tag) andalso
                    (element(1, Tag) =:= js_gen orelse
                        element(1, Tag) =:= js_gen_running))
        ->
            %% Replace the step with a permanently-DONE step and keep the `{js_gen,_}`
            %% tag, so both `.next()` and the iterator helpers (which dispatch on that
            %% tag) treat the closed generator as an empty iterator.
            erlang:put(
                ?CELL_KEY(Recv),
                {js_gen, fun(_Sent) -> iter_result(undefined, true) end}
            ),
            iter_result(arg(Args, 0), true);
        _ ->
            delegate(Recv, <<"return">>, Args)
    end;
gen_return(Recv, Args) ->
    delegate(Recv, <<"return">>, Args).

%% IteratorClose for a generator receiver (§7.4.11 as used by the Iterator
%% helpers): permanently mark the generator DONE so any later `.next()` returns
%% `{value: undefined, done: true}`. Called when a helper short-circuits (e.g.
%% `some`/`find` on a truthy predicate, `take` at its limit). A non-generator
%% receiver is left untouched (this engine models plain-object iterators without a
%% `return` method).
iter_close(Recv) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_gen, _} -> erlang:put(?CELL_KEY(Recv), js_gen_done);
        {js_gen_running, _} -> erlang:put(?CELL_KEY(Recv), js_gen_done);
        _ -> ok
    end,
    undefined;
iter_close(_) ->
    undefined.

%% ── Iterator helper methods (Iterator Helpers proposal, §27.1.4) ─────────────
%% These drive an UNDERLYING iterator — a generator cell, or any object with a
%% `next` method (via `gen_next`) — per the Iterator Helpers proposal. The
%% TERMINAL helpers (toArray/forEach/some/every/find/reduce) eagerly consume the
%% source; the LAZY helpers (map/filter/take/drop) return a NEW generator cell
%% whose step closure pulls from the source on demand. The receiver is dispatched
%% to these from the array-method entry points when it is a `{js_gen, _}` cell.

%% Advance the underlying iterator one step. Returns `done` when it is exhausted,
%% or `{value, V}` for the next yielded value. Per IteratorStep, a `next()` result
%% that is not an Object is a TypeError.
iter_step(Recv) ->
    R = gen_next(Recv, []),
    case is_reference(R) of
        true ->
            case truthy(get_prop(R, <<"done">>)) of
                1 -> done;
                0 -> {value, get_prop(R, <<"value">>)}
            end;
        false ->
            type_error(R)
    end.

%% toArray — collect every remaining value of the iterator into a new array
%% (§27.1.4.19).
iter_to_array(Recv) ->
    new_array(iter_collect(Recv, [])).
iter_collect(Recv, Acc) ->
    case iter_step(Recv) of
        done -> lists:reverse(Acc);
        {value, V} -> iter_collect(Recv, [V | Acc])
    end.

%% forEach(fn) — call `fn(value, counter)` for each value; returns undefined
%% (§27.1.4.7). The counter is a 0-based ascending index.
iter_for_each(Recv, Fn) ->
    require_callable(Fn),
    ifeach(Recv, Fn, 0).
ifeach(Recv, Fn, N) ->
    case iter_step(Recv) of
        done -> undefined;
        {value, V} ->
            call_cb(Fn, [V, N]),
            ifeach(Recv, Fn, N + 1)
    end.

%% some(fn) — the JS boolean `true` if `fn(value, counter)` is truthy for any
%% value (short-circuiting on the first truthy result), else `false` (§27.1.4.18).
iter_some(Recv, Fn) ->
    require_callable(Fn),
    isome(Recv, Fn, 0).
isome(Recv, Fn, N) ->
    case iter_step(Recv) of
        done -> false;
        {value, V} ->
            case truthy(call_cb(Fn, [V, N])) of
                1 ->
                    iter_close(Recv),
                    true;
                0 ->
                    isome(Recv, Fn, N + 1)
            end
    end.

%% every(fn) — the JS boolean `true` unless `fn(value, counter)` is falsy for some
%% value (short-circuiting on the first falsy result) (§27.1.4.6).
iter_every(Recv, Fn) ->
    require_callable(Fn),
    ievery(Recv, Fn, 0).
ievery(Recv, Fn, N) ->
    case iter_step(Recv) of
        done -> true;
        {value, V} ->
            case truthy(call_cb(Fn, [V, N])) of
                0 ->
                    iter_close(Recv),
                    false;
                1 ->
                    ievery(Recv, Fn, N + 1)
            end
    end.

%% find(fn) — the first value for which `fn(value, counter)` is truthy, else
%% undefined (§27.1.4.8).
iter_find(Recv, Fn) ->
    require_callable(Fn),
    ifind(Recv, Fn, 0).
ifind(Recv, Fn, N) ->
    case iter_step(Recv) of
        done -> undefined;
        {value, V} ->
            case truthy(call_cb(Fn, [V, N])) of
                1 ->
                    iter_close(Recv),
                    V;
                0 ->
                    ifind(Recv, Fn, N + 1)
            end
    end.

%% reduce(fn, init) — left fold seeded by `init`; the reducer is called with
%% `(accumulator, value, counter)`, counter 0-based (§27.1.4.16).
iter_reduce(Recv, Fn, Init) ->
    require_callable(Fn),
    ireduce(Recv, Fn, Init, 0).
ireduce(Recv, Fn, Acc, N) ->
    case iter_step(Recv) of
        done -> Acc;
        {value, V} -> ireduce(Recv, Fn, call_cb(Fn, [Acc, V, N]), N + 1)
    end.

%% reduce(fn) — no seed: the first value seeds the accumulator and the fold
%% continues from counter 1. An empty iterator throws a TypeError (§27.1.4.16
%% step 5.b.i).
iter_reduce1(Recv, Fn) ->
    require_callable(Fn),
    case iter_step(Recv) of
        done -> type_error(<<"Reduce of empty iterator with no initial value">>);
        {value, V} -> ireduce(Recv, Fn, V, 1)
    end.

%% map(fn) — a LAZY iterator yielding `fn(value, counter)` for each source value
%% (§27.1.4.12). The counter lives in a cell captured by the step closure.
iter_map(Recv, Fn) ->
    require_callable(Fn),
    St = cell_new(0),
    gen_make(fun(_Sent) -> imap_step(Recv, Fn, St) end).
imap_step(Recv, Fn, St) ->
    case iter_step(Recv) of
        done -> iter_result(undefined, true);
        {value, V} ->
            N = cell_get(St),
            cell_set(St, N + 1),
            iter_result(call_cb(Fn, [V, N]), false)
    end.

%% filter(fn) — a LAZY iterator yielding the source values for which
%% `fn(value, counter)` is truthy (§27.1.4.5).
iter_filter(Recv, Fn) ->
    require_callable(Fn),
    St = cell_new(0),
    gen_make(fun(_Sent) -> ifilter_step(Recv, Fn, St) end).
ifilter_step(Recv, Fn, St) ->
    case iter_step(Recv) of
        done -> iter_result(undefined, true);
        {value, V} ->
            N = cell_get(St),
            cell_set(St, N + 1),
            case truthy(call_cb(Fn, [V, N])) of
                1 -> iter_result(V, false);
                0 -> ifilter_step(Recv, Fn, St)
            end
    end.

%% take(n) — a LAZY iterator yielding at most `n` source values (§27.1.4.17). `n`
%% is ToIntegerOrInfinity(limit); a negative limit throws a RangeError.
iter_take(Recv, Limit) ->
    St = cell_new(iter_limit(Limit)),
    gen_make(fun(_Sent) -> itake_step(Recv, St) end).
itake_step(Recv, St) ->
    case cell_get(St) of
        inf ->
            itake_yield(Recv, St, inf);
        Rem when Rem =< 0 ->
            %% Limit reached: close the underlying iterator (§27.1.4.17 step 5.b.i).
            iter_close(Recv),
            iter_result(undefined, true);
        Rem ->
            itake_yield(Recv, St, Rem)
    end.
itake_yield(Recv, St, Rem) ->
    case iter_step(Recv) of
        done -> iter_result(undefined, true);
        {value, V} ->
            case Rem of
                inf -> ok;
                _ -> cell_set(St, Rem - 1)
            end,
            iter_result(V, false)
    end.

%% drop(n) — a LAZY iterator that skips the first `n` source values, then yields
%% the rest (§27.1.4.4). `n` is ToIntegerOrInfinity(limit); negative → RangeError.
iter_drop(Recv, Limit) ->
    St = cell_new({drop, iter_limit(Limit)}),
    gen_make(fun(_Sent) -> idrop_step(Recv, St) end).
idrop_step(Recv, St) ->
    case cell_get(St) of
        {drop, inf} ->
            case iter_step(Recv) of
                done -> iter_result(undefined, true);
                {value, _} -> idrop_step(Recv, St)
            end;
        {drop, Rem} when Rem > 0 ->
            case iter_step(Recv) of
                done -> iter_result(undefined, true);
                {value, _} ->
                    cell_set(St, {drop, Rem - 1}),
                    idrop_step(Recv, St)
            end;
        _ ->
            case iter_step(Recv) of
                done -> iter_result(undefined, true);
                {value, V} -> iter_result(V, false)
            end
    end.

%% ToIntegerOrInfinity for take/drop's limit, per §27.1.4.17/.4 step 3-5: NaN → 0,
%% ±Infinity preserved, otherwise truncate toward zero; a negative result throws a
%% RangeError.
iter_limit(Limit) ->
    case coerce_num(Limit) of
        nan -> 0;
        inf -> inf;
        neg_inf -> range_error(<<"Iterator limit must not be negative">>);
        N when is_integer(N), N < 0 -> range_error(<<"Iterator limit must not be negative">>);
        N when is_integer(N) -> N;
        N when is_float(N) ->
            T = trunc(N),
            case T < 0 of
                true -> range_error(<<"Iterator limit must not be negative">>);
                false -> T
            end
    end.

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
%% `x[Symbol.iterator]` — resolve to the built-in iterator-producing method bound to
%% `x` (arrays, strings, Maps, Sets, generators). A non-iterable receiver has no such
%% method, so this yields `undefined` (and `x[Symbol.iterator]()` then throws, as JS
%% does when the method is missing). This is a v1 shortcut for the well-known
%% Symbol.iterator only — there is NO general symbol-keyed property store.
get_prop(Recv, {js_symbol, {wk, iterator}, _}) ->
    builtin_iter_fn(Recv);
%% Any OTHER symbol key: no general symbol-keyed property store in v1, so reading one
%% is `undefined` (reading an absent property is not a throw).
get_prop(_Recv, {js_symbol, _, _}) ->
    undefined;
%% Reading a data property OFF a Symbol value: only `description` is exposed
%% (Symbol.prototype.description, §20.4.3.2). Every other read is `undefined`
%% (no Symbol prototype-chain data properties in v1).
get_prop({js_symbol, _Id, Desc}, Key) ->
    case Key of
        <<"description">> -> Desc;
        _ -> undefined
    end;
get_prop(Recv, Key) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_array, Len, Map} ->
            case Key of
                %% `arr.constructor` is the `Array` constructor VALUE (§23.1.3.2),
                %% fun-identical to a bare `Array` reference.
                <<"constructor">> -> builtin_ctor(<<"Array">>);
                _ -> array_get(Len, Map, Key)
            end;
        {js_regex, _, Flags, Src} ->
            case Key of
                <<"constructor">> -> builtin_ctor(<<"RegExp">>);
                <<"source">> -> Src;
                <<"flags">> -> canonical_flags(Flags);
                <<"global">> -> has_flag(Flags, $g);
                <<"ignoreCase">> -> has_flag(Flags, $i);
                <<"multiline">> -> has_flag(Flags, $m);
                <<"dotAll">> -> has_flag(Flags, $s);
                <<"sticky">> -> has_flag(Flags, $y);
                <<"unicode">> -> has_flag(Flags, $u);
                <<"unicodeSets">> -> has_flag(Flags, $v);
                <<"hasIndices">> -> has_flag(Flags, $d);
                <<"lastIndex">> -> regex_last_index_raw(Recv);
                _ -> undefined
            end;
        {js_map, _, D} ->
            case Key of
                <<"size">> -> maps:size(D);
                <<"constructor">> -> builtin_ctor(<<"Map">>);
                _ -> undefined
            end;
        {js_set, _, D} ->
            case Key of
                <<"size">> -> maps:size(D);
                <<"constructor">> -> builtin_ctor(<<"Set">>);
                _ -> undefined
            end;
        %% a generator object: arbitrary property reads are `undefined` (`.next`
        %% is dispatched by the compiler to gen_next, not via get_prop).
        {js_gen, _} ->
            undefined;
        %% a primitive wrapper: a String wrapper exposes the string primitive's
        %% `.length` / index reads; Number/Boolean wrappers have no own data props.
        %% `.constructor` is the matching constructor VALUE for every wrapper kind.
        {js_wrapper, string, Str} ->
            case Key of
                <<"constructor">> -> builtin_ctor(<<"String">>);
                _ -> string_prop(Str, Key)
            end;
        {js_wrapper, Kind, _Prim} ->
            case Key of
                <<"constructor">> -> builtin_ctor(wrapper_ctor_name(Kind));
                _ -> undefined
            end;
        %% an error exposes its own `name`/`message` data properties (§20.5.3);
        %% every other read (`stack`, `cause`, `constructor`, …) is `undefined`
        %% in this v1 model, which has no error prototype chain.
        {js_err, Name, Msg} ->
            case Key of
                <<"name">> -> Name;
                <<"message">> -> Msg;
                _ -> undefined
            end;
        M when is_map(M) ->
            %% A plain object's `.constructor` (absent an own one) is the `Object`
            %% constructor VALUE, so `({}).constructor === Object` holds. An own
            %% `constructor` property (rare) still wins.
            case Key =:= <<"constructor">> andalso not maps:is_key(<<"constructor">>, M) of
                true -> builtin_ctor(<<"Object">>);
                false -> resolve_get(maps:get(prop_key(Key), M, undefined))
            end;
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
        {js_regex, _, _, _} ->
            %% `lastIndex` is the only writable data property of a RegExp; the
            %% flag getters (`global`, `source`, …) live on the prototype and a
            %% write to them is a silent no-op in non-strict mode.
            case Key of
                <<"lastIndex">> -> regex_set_last_index(Recv, V);
                _ -> ok
            end,
            V;
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
                    %% Adding a brand-new own property to a NON-EXTENSIBLE object
                    %% (Object.preventExtensions/seal/freeze) is refused; in
                    %% non-strict mode this is a silent no-op. Writes to an
                    %% EXISTING key are unaffected (extensibility only bars new
                    %% keys — configurability/writability is a separate flag).
                    case
                        (not maps:is_key(K, M)) andalso
                            erlang:get({js_nonextensible, Recv}) =:= true
                    of
                        true ->
                            V;
                        false ->
                            erlang:put(?CELL_KEY(Recv), maps:put(K, V, M)),
                            V
                    end
            end;
        _ ->
            type_error(Recv)
    end.

%% Object.freeze(o): mark o immutable — subsequent own-property writes/deletes are
%% no-ops (non-strict mode) — and return o. Frozen-ness is tracked in a SEPARATE
%% process-dictionary entry keyed by the cell ref, so it never appears among the
%% object's keys. A non-object primitive is returned unchanged (already immutable).
object_freeze(O) when is_reference(O); is_function(O) ->
    erlang:put({js_frozen, O}, true),
    %% Freezing implies the object is also non-extensible and sealed
    %% (SetIntegrityLevel(frozen) first performs [[PreventExtensions]]), so
    %% Object.isExtensible/isSealed report the derived state correctly.
    erlang:put({js_nonextensible, O}, true),
    erlang:put({js_sealed, O}, true),
    O;
object_freeze(O) ->
    O.

%% Object.isFrozen(o) -> JS boolean. A non-object primitive is frozen (true) per
%% spec.
object_is_frozen(O) when is_reference(O); is_function(O) ->
    erlang:get({js_frozen, O}) =:= true;
object_is_frozen(_) ->
    true.

%% Object.preventExtensions(o): mark o non-extensible — no NEW own property can be
%% added afterwards (existing properties stay writable/configurable) — and return
%% o. Non-extensibility is tracked in a SEPARATE process-dictionary entry keyed by
%% the cell ref, so it never appears among the object's keys. A non-object
%% primitive is returned unchanged (it can never gain properties anyway).
object_prevent_extensions(O) when is_reference(O); is_function(O) ->
    erlang:put({js_nonextensible, O}, true),
    O;
object_prevent_extensions(O) ->
    O.

%% Object.isExtensible(o) -> Erlang boolean atom. True iff o is an object that has
%% not been made non-extensible (via preventExtensions/seal/freeze). Functions
%% (including built-in constructors) ARE objects and are extensible by default. Per
%% ES2015 (§19.1.2.13) a non-object primitive is NOT extensible, so this returns
%% `false` for it rather than throwing.
object_is_extensible(O) when is_reference(O); is_function(O) ->
    erlang:get({js_nonextensible, O}) =/= true;
object_is_extensible(_) ->
    false.

%% Object.seal(o): make o non-extensible AND mark every existing own property
%% non-configurable (they can no longer be deleted or reconfigured, but remain
%% writable), then return o. In this descriptor-free model configurability is
%% tracked with a single per-object `js_sealed` flag. A non-object primitive is
%% returned unchanged.
object_seal(O) when is_reference(O); is_function(O) ->
    erlang:put({js_nonextensible, O}, true),
    erlang:put({js_sealed, O}, true),
    O;
object_seal(O) ->
    O.

%% Object.isSealed(o) -> Erlang boolean atom, the TestIntegrityLevel(o, sealed)
%% predicate (§7.3.15): o is sealed iff it is non-extensible AND every own
%% property is non-configurable. In this model that holds when the object was
%% sealed or frozen, OR when it is non-extensible and has no own properties (the
%% integrity check is then vacuously satisfied). A non-object primitive is sealed
%% (true) per spec.
object_is_sealed(O) when is_reference(O); is_function(O) ->
    case erlang:get({js_nonextensible, O}) =:= true of
        false ->
            false;
        true ->
            erlang:get({js_sealed, O}) =:= true orelse
                erlang:get({js_frozen, O}) =:= true orelse
                obj_pairs(O) =:= []
    end;
object_is_sealed(_) ->
    true.

%% Object.is(x, y) -> JS boolean, the SameValue algorithm (§7.2.11). Like `===`
%% except NaN is SameValue with NaN, and +0 is NOT SameValue with -0. All other
%% values compare by strict identity (same type AND same value).
object_is(X, Y) ->
    same_value(X, Y).

%% SameValue(x, y): true iff x and y are the same JS value under §7.2.11.
same_value(X, Y) ->
    T = js_type(X),
    case T =:= js_type(Y) of
        false -> false;
        true ->
            case T of
                number -> same_value_number(X, Y);
                _ -> X =:= Y
            end
    end.

%% SameValue for two numbers: NaN==NaN, +0 and -0 distinguished, otherwise the
%% same numeric value. `js_nan`/`js_inf`/`js_neg_inf` sentinels and finite
%% ints/floats all flow through here.
same_value_number(js_nan, js_nan) -> true;
same_value_number(js_nan, _) -> false;
same_value_number(_, js_nan) -> false;
same_value_number(X, Y) ->
    case is_neg_zero(X) =:= is_neg_zero(Y) of
        false -> false;
        true -> num_strict_eq(num_of(X), num_of(Y)) =:= 1
    end.

%% Is `V` the IEEE negative zero (-0.0)? Determined by the sign bit of the packed
%% double so it is robust across OTP versions (Erlang float division cannot form
%% -0.0's reciprocal). An integer 0 is +0 (this model has no integer -0).
is_neg_zero(V) when is_float(V) ->
    <<Sign:1, _:63>> = <<V:64/float>>,
    V == 0.0 andalso Sign =:= 1;
is_neg_zero(_) ->
    false.

%% Object.prototype.hasOwnProperty(v) -> JS boolean: does the receiver have an
%% OWN property named ToString(v)? Per ToObject a string receiver owns its
%% indices "0".."n-1" plus "length"; number/boolean/function wrappers own no
%% string keys; null/undefined raise a TypeError (ToObject fails). This model has
%% no non-enumerable data props, so an own key is exactly a stored key.
object_has_own(Recv, Key) when is_reference(Recv) ->
    has_prop(Recv, to_string(Key)) =:= 1;
object_has_own(Recv, Key) when is_binary(Recv) ->
    K = to_string(Key),
    K =:= <<"length">> orelse
        case str_to_index(K) of
            {ok, I} -> I >= 0 andalso I < length(cps(Recv));
            error -> false
        end;
object_has_own(Recv, _Key) ->
    case js_type(Recv) of
        number -> false;
        boolean -> false;
        function -> false;
        %% ToObject(Symbol) succeeds — a Symbol wrapper owns no string keys, so
        %% `Symbol().hasOwnProperty("description")` is false (description lives on the
        %% prototype, §20.4.3.2).
        symbol -> false;
        _ -> type_error(Recv)
    end.

%% ───────────────────────── Reflect ─────────────────────────
%% The Reflect namespace (§28.1). Every method's first step is "If Type(target) is
%% not Object, throw a TypeError" — UNLIKE the matching Object.* static, which
%% ToObject-coerces a primitive. So each op guards `is_reference(Target)` (the model's
%% object representation) and calls type_error/1 for any primitive, then delegates to
%% the same core property machinery used elsewhere. This v1 model has own properties
%% only (no prototype chain), so [[HasProperty]]/[[Get]] reduce to own-key lookups.

%% Reflect.has(target, propertyKey) (§28.1.9) -> JS boolean. TypeError if target is
%% not an Object. The key is passed through unchanged (has_prop normalizes a number
%% key like `obj[k]` does); this converts the 1/0 result to the boolean atom the spec
%% requires (a VALUE, not a predicate). Own-property only here (no inherited keys in v1).
reflect_has(Target, Key) when is_reference(Target) ->
    has_prop(Target, Key) =:= 1;
reflect_has(Target, _Key) ->
    type_error(Target).

%% Reflect.get(target, propertyKey) (§28.1.6) -> the property value (or undefined).
%% TypeError if target is not an Object. The optional `receiver` (accessor `this`)
%% is not modelled; getters here are already receiver-bound by get_prop.
reflect_get(Target, Key) when is_reference(Target) ->
    get_prop(Target, Key);
reflect_get(Target, _Key) ->
    type_error(Target).

%% Reflect.set(target, propertyKey, V, Receiver) (§28.1.13) -> JS boolean success.
%% TypeError if `target` is not an Object. Implements the receiver-aware portion of
%% OrdinarySetWithOwnDescriptor (9.1.9.2) that is observable in this v1 model:
%%
%%   * A frozen `target` presents a non-writable data descriptor, so the write is
%%     refused and `false` is returned (step 5.a).
%%   * `Type(Receiver)` must be Object; a primitive receiver (string/number/…) is
%%     refused with `false` and nothing is written (step 5.b).
%%   * Otherwise the value is written on the RECEIVER, not the target (steps 5.c–f):
%%     with no explicit receiver the lowering passes `Receiver = target`, so an
%%     ordinary `Reflect.set(o, k, v)` still mutates `o`; with a distinct receiver
%%     object the value lands there and the target is left untouched.
%%   * A frozen receiver (existing property non-writable) or a non-extensible
%%     receiver that lacks the key (CreateDataProperty fails) reports `false`.
%%
%% Individual per-property writable/accessor descriptors and the prototype-chain
%% walk of step 4 are not modelled (no descriptor surface in v1).
reflect_set(Target, Key, V, Receiver) when is_reference(Target) ->
    case erlang:get({js_frozen, Target}) =:= true of
        true ->
            false;
        _ ->
            case is_reference(Receiver) of
                false ->
                    false;
                true ->
                    case erlang:get({js_frozen, Receiver}) =:= true of
                        true ->
                            false;
                        _ ->
                            HasOwn = has_prop(Receiver, Key) =:= 1,
                            NonExt =
                                erlang:get({js_nonextensible, Receiver}) =:= true,
                            case (not HasOwn) andalso NonExt of
                                true ->
                                    false;
                                false ->
                                    set_prop(Receiver, Key, V),
                                    true
                            end
                    end
            end
    end;
reflect_set(Target, _Key, _V, _Receiver) ->
    type_error(Target).

%% Reflect.deleteProperty(target, propertyKey) (§28.1.4) -> JS boolean success.
%% TypeError if target is not an Object. delete_prop already returns the boolean
%% atom (false for a frozen/sealed non-configurable own property, true otherwise).
reflect_delete_property(Target, Key) when is_reference(Target) ->
    delete_prop(Target, Key);
reflect_delete_property(Target, _Key) ->
    type_error(Target).

%% Reflect.ownKeys(target) (§28.1.11) -> an Array of the target's own property keys.
%% TypeError if target is not an Object. Reuses object_keys (the own-key list); the
%% array-index-first / creation-order guarantees follow from the backing map, a v1
%% ordering limitation shared with Object.keys.
reflect_own_keys(Target) when is_reference(Target) ->
    object_keys(Target);
reflect_own_keys(Target) ->
    type_error(Target).

%% Reflect.getPrototypeOf(target) (§28.1.8) -> the target's prototype, or null.
%% TypeError if target is not an Object. This v1 model tracks no prototype chain, so
%% an ordinary object reports `null` (LIMITED: it cannot return the real
%% Object.prototype). The value of this op is the enforced TypeError on primitives.
reflect_get_prototype_of(Target) when is_reference(Target) ->
    null;
reflect_get_prototype_of(Target) ->
    type_error(Target).

%% Reflect.isExtensible(target) (§28.1.10) -> JS boolean. TypeError if target is not
%% an Object (UNLIKE Object.isExtensible, which returns false for a primitive).
reflect_is_extensible(Target) when is_reference(Target) ->
    object_is_extensible(Target);
reflect_is_extensible(Target) ->
    type_error(Target).

%% Reflect.preventExtensions(target) (§28.1.12) -> JS boolean success. TypeError if
%% target is not an Object. Marks the object non-extensible and reports `true`.
reflect_prevent_extensions(Target) when is_reference(Target) ->
    object_prevent_extensions(Target),
    true;
reflect_prevent_extensions(Target) ->
    type_error(Target).

%% Reflect.apply(target, thisArgument, argumentsList) (§28.1.1) -> the call result.
%% TypeError if target is not callable. Reuses func_apply, whose raw-argument
%% convention is `[thisArg, argArray | _]`; a null/undefined argumentsList is the
%% empty list (CreateListFromArrayLike).
reflect_apply(Target, ThisArgument, ArgumentsList) when is_function(Target) ->
    func_apply(Target, [ThisArgument, ArgumentsList]);
reflect_apply(Target, _ThisArgument, _ArgumentsList) ->
    type_error(Target).

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

%% delete recv[key] — remove the property; returns `true` on success (non-strict).
%% A FROZEN or SEALED object has non-configurable own properties, so `delete` is a
%% no-op and reports `false` (§13.5.1.2 with a non-configurable target).
delete_prop(Recv, Key) when is_reference(Recv) ->
    case
        erlang:get({js_frozen, Recv}) =:= true orelse
            erlang:get({js_sealed, Recv}) =:= true
    of
        true ->
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

%% Every cell IS an Object, so `x instanceof Object` (compiled to a has_prop for
%% the `@@is_Object` brand) is true for every reference — array, plain object,
%% Map/Set, RegExp, Date, error, wrapper, and class instance alike. Matched ahead
%% of the tag dispatch so a single clause covers them all.
has_prop(Recv, <<"@@is_Object">>) when is_reference(Recv) ->
    1;
%% key in recv → 1|0 (own properties only, like get_prop).
has_prop(Recv, Key) when is_reference(Recv) ->
    case erlang:get(?CELL_KEY(Recv)) of
        {js_array, _Len, Map} -> array_has(Map, Key);
        %% Every Map cell IS a Map instance → `x instanceof Map` is the `@@is_Map`
        %% brand; a RegExp/Date cell likewise. (A non-brand `key in x` is 0, as for
        %% Set — these built-ins have no enumerable own string properties here.)
        {js_map, _, _} ->
            case Key of
                <<"@@is_Map">> -> 1;
                _ -> 0
            end;
        {js_regex, _, _, _} ->
            case Key of
                <<"@@is_RegExp">> -> 1;
                _ -> 0
            end;
        {js_date, _} ->
            case Key of
                <<"@@is_Date">> -> 1;
                _ -> 0
            end;
        %% A primitive-wrapper OBJECT (`new String("x")` / `new Number(1)` /
        %% `new Boolean(true)`) is `instanceof` its own kind's constructor.
        {js_wrapper, Kind, _} ->
            case Key of
                <<"@@is_", N/binary>> -> bool_int(N =:= wrapper_ctor_name(Kind));
                _ -> 0
            end;
        %% Every Set cell IS a Set instance, so `x instanceof Set` (compiled to a
        %% has_prop for the `@@is_Set` brand) is true for any Set cell.
        {js_set, _, _} ->
            case Key of
                <<"@@is_Set">> -> 1;
                _ -> 0
            end;
        %% Every WeakMap cell IS a WeakMap instance, so `x instanceof WeakMap`
        %% (compiled to a has_prop for the `@@is_WeakMap` brand) is true for any
        %% WeakMap cell.
        {js_weakmap, _, _} ->
            case Key of
                <<"@@is_WeakMap">> -> 1;
                _ -> 0
            end;
        %% Every WeakSet cell IS a WeakSet instance, so `x instanceof WeakSet`
        %% (compiled to a has_prop for the `@@is_WeakSet` brand) is true for it.
        {js_weakset, _} ->
            case Key of
                <<"@@is_WeakSet">> -> 1;
                _ -> 0
            end;
        %% `err instanceof Error` is true for every error value; `err instanceof T`
        %% is true only when T names this error's own constructor. `lower_instanceof`
        %% compiles `x instanceof T` to has_prop(x, "@@is_T"), so match the brand.
        {js_err, Name, _} ->
            case Key of
                <<"@@is_Error">> -> 1;
                <<"@@is_", N/binary>> when N =:= Name -> 1;
                _ -> 0
            end;
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

%% [e0, e1, …] — build the array from the emitter's cons list of elements. The
%% `js_hole` sentinel (emitted for an array-literal elision, `[0, , 2]`) advances the
%% length but is NOT stored, leaving that index a genuine hole (absent key) — a hole is
%% distinct from the value `undefined` per ES §13.2.4.
new_array(List) when is_list(List) ->
    {Len, Map} =
        lists:foldl(
            fun
                (js_hole, {I, M}) -> {I + 1, M};
                (E, {I, M}) -> {I + 1, maps:put(I, E, M)}
            end,
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
array_key(K) when is_integer(K) ->
    %% An integer is an array index only in [0, 2^32 - 1); every other integer
    %% (negatives, and values >= 2^32-1 such as 2^32-1 itself) is an ordinary
    %% string property that must NOT bump `length`.
    case K >= 0 andalso K < 4294967295 of
        true -> K;
        false -> integer_to_binary(K)
    end;
array_key(K) when is_float(K) ->
    case K == trunc(K) of
        true -> array_key(trunc(K));
        false -> to_string(K)
    end;
array_key(<<"length">>) -> <<"length">>;
array_key(K) when is_binary(K) ->
    case canonical_index(K) of
        {ok, I} -> I;
        error -> K
    end;
%% A boolean / null / undefined index is a PRIMITIVE key: ToPropertyKey coerces it
%% via ToString, so `arr[true]`/`arr[null]`/`arr[undefined]` address the ordinary
%% string properties "true"/"false"/"null"/"undefined" (never an array index, so
%% `length` is untouched) — ES §10.4.2.1 / §7.1.19.
array_key(true) -> <<"true">>;
array_key(false) -> <<"false">>;
array_key(null) -> <<"null">>;
array_key(undefined) -> <<"undefined">>;
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
                    fun
                        (js_hole, {I, M}) -> {I + 1, M};
                        (V, {I, M}) -> {I + 1, maps:put(I, V, M)}
                    end,
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
    %% An iterable source (Set / Map / generator) is materialized through its iterator
    %% protocol (§23.1.2.1 step 5); anything else is treated as an array-like read by
    %% integer index up to ToLength(length).
    case cell_tag(X) of
        {js_set, _, _} -> from_map_list(set_elems(X), Fn, 0);
        {js_map, _, _} -> from_map_list(map_entry_arrays(X), Fn, 0);
        {js_gen, _} -> from_map_list(drain_gen(X, []), Fn, 0);
        _ -> from_map_index(X, Fn, 0, arr_from_length(X))
    end;
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

%% `Array.prototype.<name>` as a first-class function VALUE (§23.1.3): the built-in
%% method extracted off the prototype. In this model the method is UNBOUND — its
%% `this` is supplied as the first argument — so the returned BEAM fun takes the
%% receiver first and the method's own arguments after (e.g. `Fn(Arr, I)` for
%% `at`). This makes `typeof Array.prototype.at` be "function" and the extracted
%% method callable receiver-first. `Name` is the method name as a binary; only the
%% methods the frontend routes here are known (an unknown name is a TypeError, as
%% no such own method exists).
array_proto_fn(<<"at">>) -> fun(This, I) -> array_at(This, I) end;
array_proto_fn(<<"flat">>) -> fun(This, D) -> array_flat(This, D) end;
array_proto_fn(<<"flatMap">>) -> fun(This, F) -> array_flat_map(This, F) end;
array_proto_fn(<<"findLast">>) -> fun(This, F) -> array_find_last(This, F) end;
array_proto_fn(<<"findLastIndex">>) -> fun(This, F) -> array_find_last_index(This, F) end;
array_proto_fn(Name) -> type_error(Name).

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

%% `Date.parse(string)` (§21.4.3.2) — `ToString` then parse. First tries the ISO 8601
%% Date Time String Format; when that fails it falls back to the two human-readable
%% forms this implementation itself produces (`toString` and `toUTCString`), so that
%% `Date.parse(d.toString())` and `Date.parse(d.toUTCString())` round-trip the time
%% value exactly — §21.4.3.2 requires any string produced by these methods to parse
%% back to the same value. Returns the time value (ms) or NaN when unparseable.
date_parse(V) ->
    out_ms(parse_date_string(to_string(V))).

%% Try the ISO form first (the primary Date Time String Format), then the
%% `toUTCString` and `toString` fallbacks. The first match wins; `nan` if none apply.
parse_date_string(Bin) ->
    case parse_iso(Bin) of
        nan ->
            case parse_utc_string(Bin) of
                nan -> parse_tostring(Bin);
                Ms -> Ms
            end;
        Ms ->
            Ms
    end.

%% Parse the `toUTCString` form `Www, DD Mon YYYY HH:mm:ss GMT` (§21.4.4.43) into an
%% integer time value or `nan`. The zone is always GMT (UTC). The year is 4+ digits,
%% optionally signed (expanded years).
parse_utc_string(Bin) ->
    RE =
        "^[A-Za-z]{3}, ([0-9]{2}) ([A-Za-z]{3}) (-?[0-9]{4,6}) "
        "([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT$",
    case re:run(Bin, RE, [{capture, all_but_first, binary}]) of
        {match, [Ds, MonS, Ys, Hs, Mis, Ss]} ->
            date_string_to_ms(Ys, MonS, Ds, Hs, Mis, Ss, 0);
        nomatch ->
            nan
    end.

%% Parse the `toString` form `Www Mon DD YYYY HH:mm:ss GMT±HHMM` (§21.4.4.41) into an
%% integer time value or `nan`. The `±HHMM` offset is subtracted to reach UTC (this
%% implementation always emits `+0000`, but a signed offset is accepted generally).
parse_tostring(Bin) ->
    RE =
        "^[A-Za-z]{3} ([A-Za-z]{3}) ([0-9]{2}) (-?[0-9]{4,6}) "
        "([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT([+-][0-9]{4})$",
    case re:run(Bin, RE, [{capture, all_but_first, binary}]) of
        {match, [MonS, Ds, Ys, Hs, Mis, Ss, Off]} ->
            date_string_to_ms(Ys, MonS, Ds, Hs, Mis, Ss, gmt_offset_ms(Off));
        nomatch ->
            nan
    end.

%% Build a UTC time value from the calendar fields captured from a human-readable Date
%% string. `OffMs` is the millisecond offset east-of-UTC to SUBTRACT to reach UTC.
%% Returns an integer time value, or `nan` if the month name is unknown or a field is
%% out of range.
date_string_to_ms(Ys, MonS, Ds, Hs, Mis, Ss, OffMs) ->
    case month_from_abbr(MonS) of
        nan ->
            nan;
        Mo ->
            Y = signed_int(Ys),
            D = binary_to_integer(Ds),
            H = binary_to_integer(Hs),
            Mi = binary_to_integer(Mis),
            S = binary_to_integer(Ss),
            case valid_iso(Mo, D, H, Mi, S) of
                false ->
                    nan;
                true ->
                    Day = days_from_civil(Y, Mo, D),
                    Local =
                        Day * ?MS_PER_DAY + H * 3600000 + Mi * 60000 + S * 1000,
                    time_clip(Local - OffMs)
            end
    end.

%% Milliseconds east-of-UTC for a `±HHMM` GMT offset (as emitted by `toTimeString`).
gmt_offset_ms(<<Sign, H1, H0, M1, M0>>) ->
    Mins = (H1 - $0) * 600 + (H0 - $0) * 60 + (M1 - $0) * 10 + (M0 - $0),
    case Sign of
        $- -> -Mins * 60000;
        _ -> Mins * 60000
    end.

%% Three-letter English month abbreviation → 1-based month number, or `nan` if the
%% abbreviation is not recognised (the inverse of `month_abbr/1`).
month_from_abbr(<<"Jan">>) -> 1;
month_from_abbr(<<"Feb">>) -> 2;
month_from_abbr(<<"Mar">>) -> 3;
month_from_abbr(<<"Apr">>) -> 4;
month_from_abbr(<<"May">>) -> 5;
month_from_abbr(<<"Jun">>) -> 6;
month_from_abbr(<<"Jul">>) -> 7;
month_from_abbr(<<"Aug">>) -> 8;
month_from_abbr(<<"Sep">>) -> 9;
month_from_abbr(<<"Oct">>) -> 10;
month_from_abbr(<<"Nov">>) -> 11;
month_from_abbr(<<"Dec">>) -> 12;
month_from_abbr(_) -> nan.

%% A Date instance method dispatched on the receiver's tag. When `Recv` is a Date
%% cell the field/derived value is computed from its ms; otherwise the call DELEGATES
%% to a same-named user method (so `getTime`/`valueOf`/… never clobber a user object's
%% own method). `Name` is the JS method name (a binary); `Args` the full argument list.
date_call(Recv, Name, Args) ->
    case cell_tag(Recv) of
        {js_date, Ms} ->
            case is_date_setter(Name) of
                %% Setters mutate the receiver cell, so they need `Recv`.
                true -> date_set(Recv, Name, Ms, Args);
                false -> date_field(Name, Ms, Args)
            end;
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
%% Human-readable string forms. An Invalid Date renders as "Invalid Date" for each
%% (§21.4.4.41/.35/.42/.43). Local and UTC coincide (deviation), so the local
%% `toString`/`toTimeString` render a fixed `GMT+0000` zone.
date_field(<<"toUTCString">>, nan, _) -> <<"Invalid Date">>;
date_field(<<"toUTCString">>, Ms, _) -> to_utc_string(Ms);
date_field(<<"toDateString">>, nan, _) -> <<"Invalid Date">>;
date_field(<<"toDateString">>, Ms, _) -> to_date_string(Ms);
date_field(<<"toTimeString">>, nan, _) -> <<"Invalid Date">>;
date_field(<<"toTimeString">>, Ms, _) -> to_time_string(Ms);
date_field(<<"toString">>, Ms, _) -> date_to_string(Ms);
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

%% True for the mutating Date setter method names (§21.4.4.20-30). Setters need the
%% receiver cell (to write the new [[DateValue]]), so they are dispatched from
%% `date_call` rather than `date_field`. The UTC variants coincide with the local
%% ones (module deviation).
is_date_setter(N) ->
    lists:member(N, [
        <<"setTime">>,
        <<"setMilliseconds">>,
        <<"setUTCMilliseconds">>,
        <<"setSeconds">>,
        <<"setUTCSeconds">>,
        <<"setMinutes">>,
        <<"setUTCMinutes">>,
        <<"setHours">>,
        <<"setUTCHours">>,
        <<"setDate">>,
        <<"setUTCDate">>,
        <<"setMonth">>,
        <<"setUTCMonth">>,
        <<"setFullYear">>,
        <<"setUTCFullYear">>
    ]).

%% Execute a Date setter: compute the new time value from the current time `Ms` and
%% the argument list, write it back into the receiver cell `Recv`, and RETURN it (a
%% JS number, or NaN). Per §21.4.4:
%%   - `setTime(time)` replaces the whole value with `TimeClip(ToNumber(time))`.
%%   - the field setters recompute one or more components; absent trailing arguments
%%     are taken from the current value, and any non-finite argument yields NaN.
%%   - an Invalid Date (`nan`) stays NaN for every setter EXCEPT `setFullYear`, which
%%     treats a NaN base time as +0 so the year can still be established.
date_set(Recv, <<"setTime">>, _Ms, Args) ->
    date_store(Recv, time_clip(coerce_num(arg(Args, 0))));
date_set(Recv, Name, Ms, Args) ->
    date_store(Recv, date_set_value(Name, Ms, Args)).

%% Write `{js_date, New}` into the cell and return the external time value.
date_store(Recv, New) ->
    cell_set(Recv, {js_date, New}),
    out_ms(New).

%% New time value for a field setter, or `nan`. Decomposes the current time into UTC
%% components, overlays the ones the setter provides, then re-composes via MakeDay/
%% MakeTime + TimeClip.
date_set_value(Name, Ms, Args) ->
    IsFullYear =
        Name =:= <<"setFullYear">> orelse Name =:= <<"setUTCFullYear">>,
    case Ms =:= nan andalso not IsFullYear of
        true ->
            nan;
        false ->
            %% setFullYear uses +0 as its base when the date is invalid.
            T =
                case Ms of
                    nan -> 0;
                    _ -> Ms
                end,
            MsOfDay = floor_mod(T, ?MS_PER_DAY),
            Days = (T - MsOfDay) div ?MS_PER_DAY,
            {Y, Mo1, D} = civil_from_days(Days),
            H = MsOfDay div 3600000,
            Mi = (MsOfDay div 60000) rem 60,
            S = (MsOfDay div 1000) rem 60,
            MilS = MsOfDay rem 1000,
            date_recompose(Name, {Y, Mo1 - 1, D, H, Mi, S, MilS}, Args)
    end.

%% Overlay the setter's arguments onto the current 0-based (year, month, date,
%% hours, minutes, seconds, ms) tuple, then build the time value. `component/3`
%% yields the current field when the argument is absent and `nan` for a non-finite
%% argument; any `nan` component makes the whole result NaN (MakeDay/MakeTime).
date_recompose(Name, {Y, Mo, D, H, Mi, S, MilS}, A) ->
    {NY, NMo, ND, NH, NMi, NS, NMilS} =
        case Name of
            <<"setMilliseconds">> -> {Y, Mo, D, H, Mi, S, component(A, 0, MilS)};
            <<"setUTCMilliseconds">> ->
                {Y, Mo, D, H, Mi, S, component(A, 0, MilS)};
            <<"setSeconds">> ->
                {Y, Mo, D, H, Mi, component(A, 0, S), component(A, 1, MilS)};
            <<"setUTCSeconds">> ->
                {Y, Mo, D, H, Mi, component(A, 0, S), component(A, 1, MilS)};
            <<"setMinutes">> ->
                {Y, Mo, D, H, component(A, 0, Mi), component(A, 1, S),
                    component(A, 2, MilS)};
            <<"setUTCMinutes">> ->
                {Y, Mo, D, H, component(A, 0, Mi), component(A, 1, S),
                    component(A, 2, MilS)};
            <<"setHours">> ->
                {Y, Mo, D, component(A, 0, H), component(A, 1, Mi),
                    component(A, 2, S), component(A, 3, MilS)};
            <<"setUTCHours">> ->
                {Y, Mo, D, component(A, 0, H), component(A, 1, Mi),
                    component(A, 2, S), component(A, 3, MilS)};
            <<"setDate">> -> {Y, Mo, component(A, 0, D), H, Mi, S, MilS};
            <<"setUTCDate">> -> {Y, Mo, component(A, 0, D), H, Mi, S, MilS};
            <<"setMonth">> ->
                {Y, component(A, 0, Mo), component(A, 1, D), H, Mi, S, MilS};
            <<"setUTCMonth">> ->
                {Y, component(A, 0, Mo), component(A, 1, D), H, Mi, S, MilS};
            <<"setFullYear">> ->
                {component(A, 0, Y), component(A, 1, Mo), component(A, 2, D), H,
                    Mi, S, MilS};
            <<"setUTCFullYear">> ->
                {component(A, 0, Y), component(A, 1, Mo), component(A, 2, D), H,
                    Mi, S, MilS}
        end,
    case lists:member(nan, [NY, NMo, ND, NH, NMi, NS, NMilS]) of
        true ->
            nan;
        false ->
            Day = make_day(NY, NMo, ND),
            Time = NH * 3600000 + NMi * 60000 + NS * 1000 + NMilS,
            time_clip(Day * ?MS_PER_DAY + Time)
    end.

%% `Date.prototype.toUTCString` (§21.4.4.43) for a valid time value: the
%% timezone-independent form `Www, DD Mon YYYY HH:mm:ss GMT`, e.g.
%% "Wed, 01 Jan 1970 00:00:00 GMT". The year is at least four digits, zero-padded,
%% with a leading `-` for negative (expanded) years.
to_utc_string(Ms) ->
    {Y, Mo, D, Wd, H, Mi, S} = date_parts(Ms),
    iolist_to_binary(
        io_lib:format(
            "~s, ~2..0B ~s ~s ~2..0B:~2..0B:~2..0B GMT",
            [weekday_abbr(Wd), D, month_abbr(Mo), date_year_str(Y), H, Mi, S]
        )
    ).

%% The date portion shared by `toString`/`toDateString` (§21.4.4.41/.35):
%% `Www Mon DD YYYY`, e.g. "Thu Jan 01 1970". Local == UTC (deviation).
to_date_string(Ms) ->
    {Y, Mo, D, Wd, _H, _Mi, _S} = date_parts(Ms),
    iolist_to_binary(
        io_lib:format(
            "~s ~s ~2..0B ~s",
            [weekday_abbr(Wd), month_abbr(Mo), D, date_year_str(Y)]
        )
    ).

%% The time portion shared by `toString`/`toTimeString` (§21.4.4.41/.42):
%% `HH:mm:ss GMT+0000`. The zone is fixed at +0000 because local == UTC (deviation).
to_time_string(Ms) ->
    {_Y, _Mo, _D, _Wd, H, Mi, S} = date_parts(Ms),
    iolist_to_binary(
        io_lib:format("~2..0B:~2..0B:~2..0B GMT+0000", [H, Mi, S])
    ).

%% Decompose a valid integer time value into its UTC calendar fields:
%% `{Year, Month1, Date, Weekday, Hours, Minutes, Seconds}` where `Month1` is
%% 1-based and `Weekday` is 0=Sunday.
date_parts(Ms) ->
    MsOfDay = floor_mod(Ms, ?MS_PER_DAY),
    Days = (Ms - MsOfDay) div ?MS_PER_DAY,
    {Y, Mo, D} = civil_from_days(Days),
    Wd = floor_mod(Days + 4, 7),
    H = MsOfDay div 3600000,
    Mi = (MsOfDay div 60000) rem 60,
    S = (MsOfDay div 1000) rem 60,
    {Y, Mo, D, Wd, H, Mi, S}.

%% Three-letter English weekday abbreviation for a day index (0=Sunday).
weekday_abbr(0) -> "Sun";
weekday_abbr(1) -> "Mon";
weekday_abbr(2) -> "Tue";
weekday_abbr(3) -> "Wed";
weekday_abbr(4) -> "Thu";
weekday_abbr(5) -> "Fri";
weekday_abbr(6) -> "Sat".

%% Three-letter English month abbreviation for a 1-based month number.
month_abbr(1) -> "Jan";
month_abbr(2) -> "Feb";
month_abbr(3) -> "Mar";
month_abbr(4) -> "Apr";
month_abbr(5) -> "May";
month_abbr(6) -> "Jun";
month_abbr(7) -> "Jul";
month_abbr(8) -> "Aug";
month_abbr(9) -> "Sep";
month_abbr(10) -> "Oct";
month_abbr(11) -> "Nov";
month_abbr(12) -> "Dec".

%% The year field used by the human-readable string forms: at least four digits,
%% zero-padded, with a leading `-` for negative years (e.g. -1 -> "-0001",
%% 20 -> "0020", -123456 -> "-123456"). Per §21.4.4 DateString/ToUTCString the
%% width is a MINIMUM — expanded years (5+ digits) keep every digit. `io_lib`'s
%% fixed-width `~4..0B` cannot express this: it overflows to `*` characters when the
%% value needs more than four digits, so the padding is done by hand.
date_year_str(Y) ->
    Digits = pad_year_digits(integer_to_binary(abs(Y))),
    case Y < 0 of
        true -> <<"-", Digits/binary>>;
        false -> Digits
    end.

%% Left-zero-pad a decimal year to a MINIMUM of four digits; a wider year is returned
%% unchanged (so year -123456 keeps all six digits).
pad_year_digits(Bin) when byte_size(Bin) >= 4 -> Bin;
pad_year_digits(Bin) -> pad_year_digits(<<"0", Bin/binary>>).

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
            time_clip(make_date(Day, H, Mi, S, MilS))
    end.

%% MakeTime + MakeDate (§21.4.1.13/.14) done with IEEE-754 double arithmetic, as the
%% spec mandates: `Date.UTC`/`new Date(components)` perform the multiplications and
%% additions on Numbers, so components far beyond 2^53 lose precision in a DEFINED way
%% (e.g. `Date.UTC(1970,0,1,80063993375,29,1,-288230376151711740)` is 29312, not the
%% exact bignum result). `Day` is the integer day count; H/Mi/S/MilS are integers
%% already truncated by ToIntegerOrInfinity. The exact grouping matches the spec:
%% MakeTime = ((h·msPerHour + m·msPerMinute) + s·msPerSecond) + milli, and
%% MakeDate = day·msPerDay + time. A float overflow on an astronomically large year is
%% caught and reported as `inf`, which TimeClip maps to NaN. Returns a float or `inf`.
make_date(Day, H, Mi, S, MilS) ->
    try
        Time =
            (float(H) * 3600000 + float(Mi) * 60000) + float(S) * 1000 +
                float(MilS),
        float(Day) * ?MS_PER_DAY + Time
    catch
        error:badarith -> inf
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

%% A Date's string form, used by both `Date.prototype.toString` (§21.4.4.41 →
%% ToDateString) and string coercion (`String(date)` / `"" + date`): the long form
%% `Www Mon DD YYYY HH:mm:ss GMT+0000`, or "Invalid Date" for NaN. The zone is fixed
%% at +0000 because local == UTC (module deviation), but the layout now matches the
%% spec's ToDateString rather than the ISO form.
date_to_string(nan) -> <<"Invalid Date">>;
date_to_string(Ms) ->
    <<(to_date_string(Ms))/binary, " ", (to_time_string(Ms))/binary>>.

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
%% A Map is a cell `{js_map, Next, Data}` and a Set `{js_set, Next, Data}`. For a
%% Map, `Data` is an Erlang map `Key => {Seq, Value}`; for a Set, `Value => Seq`.
%% `Seq` is a per-collection monotonically increasing insertion index and `Next` the
%% next index to hand out; iteration (forEach / keys / values / entries) walks entries
%% in ascending `Seq`, i.e. INSERTION ORDER as the spec requires (23.1.3.5 etc.).
%% Updating an existing key keeps its `Seq` (position); a delete-then-re-insert gets a
%% fresh (larger) `Seq`, so it moves to the end.
%%
%% Key equality is SameValueZero: `mapkey_norm/1` folds every integral float to the
%% equal integer (so `1` and `1.0` are one key) and `-0` to `+0`, and NaN is already the
%% single `js_nan` sentinel — so all NaN keys coincide. The method names
%% (set/get/add/has/delete/clear/forEach/keys/values/entries) DELEGATE to a user method
%% of the same name when the receiver is a plain object, so they don't clobber user APIs.

new_map(Init) ->
    M = cell_new({js_map, 0, #{}}),
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
    S = cell_new({js_set, 0, #{}}),
    case is_array(Init) of
        1 ->
            {Len, Map} = arr_content(Init),
            lists:foreach(fun(V) -> js_m_add(S, [V]) end, arr_list(Len, Map));
        0 ->
            ok
    end,
    S.

%% Map.groupBy(items, callbackfn) (sec-map.groupby / GroupBy AO with COLLECTION key
%% coercion). Iterates `items` through the iterator protocol (arrays, strings by code
%% point, Sets/Maps/generators — via array_from_elems), calls callbackfn(value, index)
%% for each element, and collects the elements into a fresh Map keyed by the callback's
%% result. Key equality is SameValueZero (mapkey_norm): -0 folds to +0 and integral
%% floats to the equal integer, but a number key and the equal string key stay distinct
%% (no ToPropertyKey conversion, unlike Object.groupBy). Each value in the returned Map
%% is an Array of the grouped elements in iteration order. A non-callable callbackfn is
%% a TypeError thrown before any element is visited (GroupBy step 2).
map_group_by(Items, Fn) ->
    case is_function(Fn) of
        true -> ok;
        false -> not_callable(Fn)
    end,
    M = cell_new({js_map, 0, #{}}),
    group_into_map(M, Fn, array_from_elems(Items, undefined), 0),
    M.

group_into_map(_M, _Fn, [], _I) ->
    ok;
group_into_map(M, Fn, [E | Es], I) ->
    K = call_cb(Fn, [E, I]),
    case js_m_has(M, [K]) of
        true -> array_push(js_m_get(M, [K]), [E]);
        false -> js_m_set(M, [K, new_array([E])])
    end,
    group_into_map(M, Fn, Es, I + 1).

%% A WeakMap is a cell `{js_weakmap, Next, Data}`, mirroring the ordinary Map cell so
%% the shared collection-method dispatch (`js_m_set`/`get`/`has`/`delete`) can reuse
%% `mapkey_norm` and the same `Key => {Seq, Value}` storage. No real weak references
%% are modelled — entries are held strongly (test262 exercises the API surface, not
%% garbage collection). The spec (§24.3) requires every key to be an object; a
%% primitive key is rejected on `set` (TypeError) and treated as absent by
%% `get`/`has`/`delete`, enforced in those method arms via `can_be_held_weakly/1`.
%%
%% `new WeakMap(iterable?)` seeds each `[key, value]` pair through `js_m_set`, so a
%% non-object key in the initial iterable throws a TypeError just as an explicit
%% `.set(prim, v)` would (§24.3.1.1 → WeakMap.prototype.set step 4).
new_weakmap(Init) ->
    M = cell_new({js_weakmap, 0, #{}}),
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

%% The WeakMap constructor as a first-class fun VALUE, so a BARE `WeakMap` reference
%% has `typeof` "function" (sec-weakmap-constructor). Applied through a closure call
%% site it constructs a WeakMap from the optional iterable, mirroring `error_ctor/1`.
weakmap_ctor() ->
    fun(Init) -> new_weakmap(Init) end.

%% ── WeakSet (§24.4) ──────────────────────────────────────
%% A WeakSet is a cell `{js_weakset, Data}` where `Data` is an Erlang map
%% `Element => true`. Only values that CanBeHeldWeakly (§7.3.35 — Objects and,
%% in this model, functions; Symbols are unsupported) may be stored, so keys are
%% always references/funs and no SameValueZero float folding is needed (each
%% object is identity-distinct). We do NOT model real weak references — an added
%% element is retained for the collection's lifetime; that is unobservable to
%% conformant code, which cannot enumerate a WeakSet. There is no iteration,
%% ordering, size, or clear on a WeakSet, so no insertion sequence is tracked.
%%
%% The `add`/`has`/`delete` method names are shared with Map/Set and dispatch on
%% the cell tag in `js_m_add`/`js_m_has`/`js_m_delete`.

%% CanBeHeldWeakly(v) (§7.3.35): true for an Object (a cell reference) or a
%% function value. Everything else — numbers, strings, booleans, null, undefined,
%% the number sentinels — is a primitive that cannot be a WeakSet element.
can_be_held_weakly(V) -> is_reference(V) orelse is_function(V).

%% `new WeakSet([iterable])` (§24.4.1.1). With no argument (or `undefined`/`null`)
%% builds an empty WeakSet. With an array, adds each element via `js_m_add`, which
%% throws a TypeError for any element that cannot be held weakly (step 8's adder).
%% A non-array, non-null/undefined argument is not iterable in this model, so
%% GetIterator throws a TypeError (matching `new WeakSet({})`).
new_weakset(Init) ->
    S = cell_new({js_weakset, #{}}),
    case Init of
        undefined ->
            ok;
        null ->
            ok;
        _ ->
            case is_array(Init) of
                1 ->
                    {Len, Map} = arr_content(Init),
                    lists:foreach(fun(V) -> js_m_add(S, [V]) end, arr_list(Len, Map));
                0 ->
                    type_error(Init)
            end
    end,
    S.

%% The bare `WeakSet` identifier as a first-class value: a function object, so
%% `typeof WeakSet` is "function". Calling it as a plain function (without `new`)
%% throws a TypeError (§24.4.1.1 step 1 — NewTarget must be defined).
weakset_ctor() ->
    fun(_) -> weakset_no_new() end.

%% `WeakSet(...)` invoked WITHOUT `new` — §24.4.1.1 step 1 requires NewTarget to
%% be defined, so a plain call always throws a TypeError.
weakset_no_new() ->
    type_error(<<"Constructor WeakSet requires 'new'">>).

%% ───────────────────────── Symbol ─────────────────────────
%% A Symbol is a `{js_symbol, Id, Desc}` tuple. `Id` is the identity: a user Symbol
%% gets a process-unique monotonic integer (so two `Symbol()` calls are never equal,
%% even with the same description); a well-known Symbol gets a `{wk, Name}` tag (so
%% `Symbol.iterator === Symbol.iterator`); a registered Symbol (`Symbol.for`) reuses
%% the same tuple for the same string key. `Desc` is the string description or the
%% `undefined` atom. Structural tuple equality gives Symbol identity for `===`/`==`
%% (see `strict_eq`), and `js_type` maps the tuple to the `symbol` type.

%% `Symbol(description)` (§20.4.1.1): a fresh unique Symbol. NewTarget must be
%% undefined (enforced at the call site — `new Symbol()` routes to `symbol_no_new`).
%% Per step 2, an `undefined` description yields NO description; otherwise the
%% description is ToString(description).
symbol_make(Desc) ->
    D =
        case Desc of
            undefined -> undefined;
            _ -> to_string_dispatch(Desc)
        end,
    {js_symbol, erlang:unique_integer([positive, monotonic]), D}.

%% The bare `Symbol` identifier as a first-class value: a function object, so
%% `typeof Symbol` is "function". Applied as a plain function it constructs a Symbol
%% from its (single) description argument, mirroring `Symbol(desc)`.
symbol_ctor() ->
    fun(Desc) -> symbol_make(Desc) end.

%% `new Symbol()` (§20.4.1.1 step 1): the Symbol constructor is not new-able — a
%% TypeError is thrown.
symbol_no_new() ->
    type_error(<<"Symbol is not a constructor">>).

%% A well-known Symbol (§20.4.2.x) — a single fixed unique value per `Name` (an atom
%% such as `iterator`, `asyncIterator`, `hasInstance`, …). Its identity is the
%% `{wk, Name}` tag, and its description is `"Symbol.<name>"` per the spec table, so
%% `Symbol.iterator.toString()` is `"Symbol(Symbol.iterator)"`.
symbol_wellknown(Name) when is_atom(Name) ->
    {js_symbol, {wk, Name}, <<"Symbol.", (atom_to_binary(Name, utf8))/binary>>}.

%% `Symbol.for(key)` (§20.4.2.2): the GlobalSymbolRegistry lookup — returns the
%% existing Symbol registered under ToString(key), creating (and registering) a fresh
%% one on the first request for that key. The registry lives in the process
%% dictionary; a forward entry maps the string key to the Symbol and a reverse entry
%% maps the Symbol's Id to the key (for `Symbol.keyFor`).
symbol_for(Key) ->
    K = to_string_dispatch(Key),
    case erlang:get({js_symbol_registry, K}) of
        undefined ->
            Sym = {js_symbol, erlang:unique_integer([positive, monotonic]), K},
            erlang:put({js_symbol_registry, K}, Sym),
            erlang:put({js_symbol_registry_rev, sym_id(Sym)}, K),
            Sym;
        Sym ->
            Sym
    end.

%% `Symbol.keyFor(sym)` (§20.4.2.7): the registry key a Symbol was registered under
%% via `Symbol.for`, or `undefined` if it is not a registered Symbol (this includes
%% every `Symbol()` and every well-known Symbol). A non-Symbol argument is a
%% TypeError (step 1).
symbol_key_for({js_symbol, _, _} = Sym) ->
    case erlang:get({js_symbol_registry_rev, sym_id(Sym)}) of
        undefined -> undefined;
        K -> K
    end;
symbol_key_for(NotSym) ->
    type_error(NotSym).

sym_id({js_symbol, Id, _}) -> Id.

%% SymbolDescriptiveString (§20.4.3.3.1): `"Symbol(" ++ desc ++ ")"`, an absent
%% description contributing the empty string.
symbol_to_string({js_symbol, _, undefined}) ->
    <<"Symbol()">>;
symbol_to_string({js_symbol, _, Desc}) ->
    <<"Symbol(", Desc/binary, ")">>.

%% SameValueZero key canonicalization. An integral float becomes the equal integer
%% (unifying `1`/`1.0` and collapsing `-0.0` to `0`); every other term (non-integral
%% float, string, boolean, ref, the `js_nan`/`js_inf`/`js_neg_inf` sentinels) is left as
%% is. Guarantees that keys the spec deems equal share one Erlang map key.
mapkey_norm(F) when is_float(F) ->
    T = trunc(F),
    case T == F of
        true -> T;
        false -> F
    end;
mapkey_norm(K) -> K.

%% Each collection method takes the receiver + the FULL argument list, so that a
%% delegated user method (when the receiver is a plain object) gets all its arguments.

js_m_set(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, Next, D} ->
            K = mapkey_norm(arg(Args, 0)),
            V = arg(Args, 1),
            {Next2, Seq} =
                case maps:get(K, D, undefined) of
                    {OldSeq, _} -> {Next, OldSeq};
                    undefined -> {Next + 1, Next}
                end,
            erlang:put(?CELL_KEY(Recv), {js_map, Next2, maps:put(K, {Seq, V}, D)}),
            Recv;
        {js_weakmap, Next, D} ->
            %% WeakMap.prototype.set (§24.3.3.3): a key that cannot be held weakly
            %% (any primitive) is a TypeError; otherwise store as an ordinary Map.
            K = arg(Args, 0),
            case can_be_held_weakly(K) of
                false ->
                    type_error(K);
                true ->
                    V = arg(Args, 1),
                    {Next2, Seq} =
                        case maps:get(K, D, undefined) of
                            {OldSeq, _} -> {Next, OldSeq};
                            undefined -> {Next + 1, Next}
                        end,
                    erlang:put(?CELL_KEY(Recv), {js_weakmap, Next2, maps:put(K, {Seq, V}, D)}),
                    Recv
            end;
        _ ->
            delegate(Recv, <<"set">>, Args)
    end.

js_m_get(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, _, D} ->
            case maps:get(mapkey_norm(arg(Args, 0)), D, undefined) of
                {_Seq, V} -> V;
                undefined -> undefined
            end;
        {js_weakmap, _, D} ->
            %% WeakMap.prototype.get (§24.3.3.1): a key that cannot be held weakly is
            %% never present, so return undefined WITHOUT throwing.
            case maps:get(arg(Args, 0), D, undefined) of
                {_Seq, V} -> V;
                undefined -> undefined
            end;
        _ ->
            delegate(Recv, <<"get">>, Args)
    end.

js_m_add(Recv, Args) ->
    case cell_tag(Recv) of
        {js_set, Next, D} ->
            V = mapkey_norm(arg(Args, 0)),
            {Next2, D2} =
                case maps:is_key(V, D) of
                    true -> {Next, D};
                    false -> {Next + 1, maps:put(V, Next, D)}
                end,
            erlang:put(?CELL_KEY(Recv), {js_set, Next2, D2}),
            Recv;
        %% WeakSet.prototype.add (§24.4.3.1): the value MUST be able to be held
        %% weakly, else a TypeError is thrown; a duplicate is a no-op. Returns the
        %% WeakSet.
        {js_weakset, D} ->
            V = arg(Args, 0),
            case can_be_held_weakly(V) of
                true ->
                    erlang:put(?CELL_KEY(Recv), {js_weakset, maps:put(V, true, D)}),
                    Recv;
                false ->
                    type_error(V)
            end;
        _ ->
            delegate(Recv, <<"add">>, Args)
    end.

js_m_has(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, _, D} -> maps:is_key(mapkey_norm(arg(Args, 0)), D);
        {js_set, _, D} -> maps:is_key(mapkey_norm(arg(Args, 0)), D);
        %% WeakMap.prototype.has (§24.3.3.2): a key that cannot be held weakly is
        %% never present (returns false without throwing); an object key is a plain
        %% membership test.
        {js_weakmap, _, D} -> maps:is_key(arg(Args, 0), D);
        %% WeakSet.prototype.has (§24.4.3.4): a value that cannot be held weakly is
        %% never a member, so return false without throwing.
        {js_weakset, D} ->
            V = arg(Args, 0),
            can_be_held_weakly(V) andalso maps:is_key(V, D);
        _ -> delegate(Recv, <<"has">>, Args)
    end.

%% delete returns `true` only when an entry was actually removed, `false` otherwise
%% (Map.prototype.delete step 6 / Set.prototype.delete step 6).
js_m_delete(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, Next, D} ->
            K = mapkey_norm(arg(Args, 0)),
            case maps:is_key(K, D) of
                true ->
                    erlang:put(?CELL_KEY(Recv), {js_map, Next, maps:remove(K, D)}),
                    true;
                false ->
                    false
            end;
        {js_set, Next, D} ->
            V = mapkey_norm(arg(Args, 0)),
            case maps:is_key(V, D) of
                true ->
                    erlang:put(?CELL_KEY(Recv), {js_set, Next, maps:remove(V, D)}),
                    true;
                false ->
                    false
            end;
        {js_weakmap, Next, D} ->
            %% WeakMap.prototype.delete (§24.3.3.4): removes and returns true only
            %% when an entry existed; a key that cannot be held weakly is never
            %% present, so this returns false without throwing.
            K = arg(Args, 0),
            case maps:is_key(K, D) of
                true ->
                    erlang:put(?CELL_KEY(Recv), {js_weakmap, Next, maps:remove(K, D)}),
                    true;
                false ->
                    false
            end;
        %% WeakSet.prototype.delete (§24.4.3.3): removes an element and returns true
        %% only when it was present; a value that cannot be held weakly (so was never
        %% a member) returns false without throwing.
        {js_weakset, D} ->
            V = arg(Args, 0),
            case can_be_held_weakly(V) andalso maps:is_key(V, D) of
                true ->
                    erlang:put(?CELL_KEY(Recv), {js_weakset, maps:remove(V, D)}),
                    true;
                false ->
                    false
            end;
        _ ->
            delegate(Recv, <<"delete">>, Args)
    end.

js_m_clear(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, Next, _} ->
            erlang:put(?CELL_KEY(Recv), {js_map, Next, #{}}),
            undefined;
        {js_set, Next, _} ->
            erlang:put(?CELL_KEY(Recv), {js_set, Next, #{}}),
            undefined;
        _ ->
            delegate(Recv, <<"clear">>, Args)
    end.

%% Map.prototype.getOrInsert(key, value) — the TC39 `upsert` proposal
%% (sec-map.prototype.getorinsert). Canonicalizes `key` with SameValueZero
%% (`mapkey_norm`), then: if an entry for `key` already exists, returns its EXISTING
%% value and does NOT overwrite it; otherwise appends `{key, value}` as the last entry
%% and returns `value`. On a non-Map receiver, delegates to a same-named user method.
js_m_get_or_insert(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, Next, D} ->
            K = mapkey_norm(arg(Args, 0)),
            case maps:get(K, D, undefined) of
                {_Seq, V} ->
                    V;
                undefined ->
                    V = arg(Args, 1),
                    erlang:put(?CELL_KEY(Recv), {js_map, Next + 1, maps:put(K, {Next, V}, D)}),
                    V
            end;
        {js_weakmap, Next, D} ->
            %% WeakMap.prototype.getOrInsert (upsert proposal, step 3): a key that
            %% cannot be held weakly is a TypeError; otherwise behaves like the Map
            %% arm (object keys compare by identity, so no SameValueZero folding).
            K = arg(Args, 0),
            case can_be_held_weakly(K) of
                false ->
                    type_error(K);
                true ->
                    case maps:get(K, D, undefined) of
                        {_Seq, V} ->
                            V;
                        undefined ->
                            V = arg(Args, 1),
                            erlang:put(?CELL_KEY(Recv), {js_weakmap, Next + 1, maps:put(K, {Next, V}, D)}),
                            V
                    end
            end;
        _ ->
            delegate(Recv, <<"getOrInsert">>, Args)
    end.

%% Map.prototype.getOrInsertComputed(key, callbackfn) — the TC39 `upsert` proposal
%% (sec-map.prototype.getorinsertcomputed). Canonicalizes `key`; if an entry already
%% exists, returns its value WITHOUT invoking `callbackfn`. Otherwise calls
%% `callbackfn(canonicalKey)` (the canonical key is passed as the single argument),
%% then — re-reading the live map, since the callback may have mutated it — sets the
%% entry for `key` to the callback's RETURN value and returns it. The return value
%% wins over any mutation the callback made to the same key (step 6 re-scan). A
%% re-inserted key keeps its position if the callback already created it, else appends.
%% On a non-Map receiver, delegates to a same-named user method.
js_m_get_or_insert_computed(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, _, D} ->
            %% Map.prototype.getOrInsertComputed step 3: a non-callable callbackfn is a
            %% TypeError, thrown BEFORE the key lookup — so it fires even when the key
            %% is already present (and thus the callback would never be invoked).
            Fn = arg(Args, 1),
            case is_function(Fn) of
                true -> ok;
                false -> not_callable(Fn)
            end,
            K = mapkey_norm(arg(Args, 0)),
            case maps:get(K, D, undefined) of
                {_Seq, V} ->
                    V;
                undefined ->
                    Value = call_cb(Fn, [K]),
                    {js_map, Next2, D2} = cell_tag(Recv),
                    {Next3, Seq} =
                        case maps:get(K, D2, undefined) of
                            {OldSeq, _} -> {Next2, OldSeq};
                            undefined -> {Next2 + 1, Next2}
                        end,
                    erlang:put(?CELL_KEY(Recv), {js_map, Next3, maps:put(K, {Seq, Value}, D2)}),
                    Value
            end;
        {js_weakmap, _, D} ->
            %% WeakMap.prototype.getOrInsertComputed (upsert proposal, step 3): a key
            %% that cannot be held weakly is a TypeError. Otherwise, if present return
            %% the existing value WITHOUT invoking the callback; else call
            %% callbackfn(key), then store its return value (re-reading the live cell,
            %% since the callback may have mutated the WeakMap).
            K = arg(Args, 0),
            case can_be_held_weakly(K) of
                false ->
                    type_error(K);
                true ->
                    %% Step 4 (after CanBeHeldWeakly): a non-callable callbackfn is a
                    %% TypeError, thrown before the lookup so a present key still throws.
                    Fn = arg(Args, 1),
                    case is_function(Fn) of
                        true -> ok;
                        false -> not_callable(Fn)
                    end,
                    case maps:get(K, D, undefined) of
                        {_Seq, V} ->
                            V;
                        undefined ->
                            Value = call_cb(Fn, [K]),
                            {js_weakmap, Next2, D2} = cell_tag(Recv),
                            {Next3, Seq} =
                                case maps:get(K, D2, undefined) of
                                    {OldSeq, _} -> {Next2, OldSeq};
                                    undefined -> {Next2 + 1, Next2}
                                end,
                            erlang:put(?CELL_KEY(Recv), {js_weakmap, Next3, maps:put(K, {Seq, Value}, D2)}),
                            Value
                    end
            end;
        _ ->
            delegate(Recv, <<"getOrInsertComputed">>, Args)
    end.

%% forEach across arrays, Maps (fn(v, k, m)), Sets (fn(v, v, s)), or a user method.
%% For Maps/Sets the walk is by ascending Seq and RE-READS the live cell between calls,
%% so entries inserted during iteration are visited and entries deleted before they are
%% reached are skipped (23.1.3.5 / 23.2.3.6, which iterate the live entries list).
js_m_foreach(Recv, Args) ->
    Fn = arg(Args, 0),
    case is_array(Recv) of
        1 ->
            array_foreach(Recv, Fn);
        0 ->
            case cell_tag(Recv) of
                {js_map, _, _} ->
                    %% §23.1.3.5 step 3: reject a non-callable callbackfn with a
                    %% TypeError BEFORE visiting any entry (an empty map is not a
                    %% licence to skip the check).
                    case is_function(Fn) of
                        true -> ok;
                        false -> not_callable(Fn)
                    end,
                    map_foreach(Recv, Fn, -1),
                    undefined;
                {js_set, _, _} ->
                    %% §23.2.3.6 step 3: reject a non-callable callbackfn with a
                    %% TypeError BEFORE visiting any entry.
                    case is_function(Fn) of
                        true -> ok;
                        false -> not_callable(Fn)
                    end,
                    set_foreach(Recv, Fn, -1),
                    undefined;
                {js_gen, _} ->
                    %% Iterator.prototype.forEach — call fn(value, counter) for
                    %% every value the generator yields (§27.1.4.7).
                    iter_for_each(Recv, Fn);
                _ ->
                    delegate(Recv, <<"forEach">>, Args)
            end
    end.

map_foreach(Recv, Fn, Last) ->
    case next_map_entry(Recv, Last) of
        none ->
            ok;
        {Seq, K, V} ->
            call_cb(Fn, [V, K, Recv]),
            map_foreach(Recv, Fn, Seq)
    end.

set_foreach(Recv, Fn, Last) ->
    case next_set_entry(Recv, Last) of
        none ->
            ok;
        {Seq, V} ->
            call_cb(Fn, [V, V, Recv]),
            set_foreach(Recv, Fn, Seq)
    end.

%% The live entry with the smallest Seq strictly greater than `Last`, or `none`.
next_map_entry(Recv, Last) ->
    case cell_tag(Recv) of
        {js_map, _, D} ->
            maps:fold(
                fun
                    (K, {Seq, V}, none) when Seq > Last -> {Seq, K, V};
                    (K, {Seq, V}, {BSeq, _, _}) when Seq > Last, Seq < BSeq -> {Seq, K, V};
                    (_, _, Acc) -> Acc
                end,
                none,
                D
            );
        _ ->
            none
    end.

next_set_entry(Recv, Last) ->
    case cell_tag(Recv) of
        {js_set, _, D} ->
            maps:fold(
                fun
                    (V, Seq, none) when Seq > Last -> {Seq, V};
                    (V, Seq, {BSeq, _}) when Seq > Last, Seq < BSeq -> {Seq, V};
                    (_, _, Acc) -> Acc
                end,
                none,
                D
            );
        _ ->
            none
    end.

%% keys/values/entries — a LIVE iterator object (a generator cell driven by `.next()`).
%% Kind selects what each step yields: `key`, `value`, or an `[k, v]` (`[v, v]` for a
%% Set) entry array. A private cursor cell remembers the last Seq visited; each step
%% re-reads the live collection, so additions/deletions during iteration are honoured
%% (CreateMapIterator / CreateSetIterator).
js_m_keys(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, _, _} -> make_map_iter(Recv, key);
        {js_set, _, _} -> make_set_iter(Recv, value);
        %% Array.prototype.keys (§23.1.3.17) — a CreateArrayIterator over indices.
        {js_array, _, _} -> make_array_iter(Recv, key);
        _ -> delegate(Recv, <<"keys">>, Args)
    end.

js_m_values(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, _, _} -> make_map_iter(Recv, value);
        {js_set, _, _} -> make_set_iter(Recv, value);
        %% Array.prototype.values (§23.1.3.36) — a CreateArrayIterator over elements.
        {js_array, _, _} -> make_array_iter(Recv, value);
        _ -> delegate(Recv, <<"values">>, Args)
    end.

js_m_entries(Recv, Args) ->
    case cell_tag(Recv) of
        {js_map, _, _} -> make_map_iter(Recv, entry);
        {js_set, _, _} -> make_set_iter(Recv, entry);
        %% Array.prototype.entries (§23.1.3.4) — CreateArrayIterator over `[index, value]`.
        {js_array, _, _} -> make_array_iter(Recv, entry);
        _ -> delegate(Recv, <<"entries">>, Args)
    end.

%% ─────────────────── ES2024 Set composition methods ───────────────────
%% union / intersection / difference / symmetricDifference / isDisjointFrom /
%% isSubsetOf / isSupersetOf (23.2.3.x). Each takes the receiver Set and one
%% "other" argument. Per the spec the argument is coerced via GetSetRecord, which
%% treats any object exposing numeric `size` + callable `has`/`keys` as set-like;
%% here we implement the common cases where `other` is a Set (or, used set-like, a
%% Map — its keys are the elements). SameValueZero membership is inherited from the
%% Set cell's mapkey_norm'd keys, so 1/1.0 and -0/+0 coincide and NaN is a single
%% element. The receiver must be a Set cell, else a TypeError is raised
%% (RequireInternalSlot). Composition methods return a fresh Set; predicates return
%% a JS boolean (`true`/`false`).

%% Elements of a Set cell in insertion order (ascending Seq).
set_elems(Recv) ->
    case cell_tag(Recv) of
        {js_set, _, D} ->
            Sorted = lists:sort(fun({_, A}, {_, B}) -> A =< B end, maps:to_list(D)),
            [V || {V, _} <- Sorted];
        _ ->
            []
    end.

%% Number of elements in a Set cell.
set_size(Recv) ->
    case cell_tag(Recv) of
        {js_set, _, D} -> maps:size(D);
        _ -> 0
    end.

%% SameValueZero membership test against a Set cell.
set_has_elem(Recv, V0) ->
    V = mapkey_norm(V0),
    case cell_tag(Recv) of
        {js_set, _, D} -> maps:is_key(V, D);
        _ -> false
    end.

%% GetSetRecord-style view of the `other` argument: its element count.
setlike_size(Other) ->
    case cell_tag(Other) of
        {js_set, _, D} -> maps:size(D);
        {js_map, _, D} -> maps:size(D);
        _ -> 0
    end.

%% GetSetRecord-style membership on the `other` argument (Set values / Map keys).
setlike_has(Other, V0) ->
    V = mapkey_norm(V0),
    case cell_tag(Other) of
        {js_set, _, D} -> maps:is_key(V, D);
        {js_map, _, D} -> maps:is_key(V, D);
        _ -> false
    end.

%% GetSetRecord-style key iteration of the `other` argument, in insertion order.
setlike_elems(Other) ->
    case cell_tag(Other) of
        {js_set, _, _} ->
            set_elems(Other);
        {js_map, _, D} ->
            Sorted = lists:sort(
                fun({_, {A, _}}, {_, {B, _}}) -> A =< B end, maps:to_list(D)
            ),
            [K || {K, _} <- Sorted];
        _ ->
            []
    end.

%% Build a fresh Set cell from a list of elements (later duplicates ignored, first
%% occurrence fixes the position — matching insertion order).
set_from_elems(Elems) ->
    S = cell_new({js_set, 0, #{}}),
    lists:foreach(fun(V) -> js_m_add(S, [V]) end, Elems),
    S.

%% RequireInternalSlot(O, [[SetData]]) — the receiver of a Set method must be a Set.
require_set(Recv) ->
    case cell_tag(Recv) of
        {js_set, _, _} -> ok;
        _ -> type_error(Recv)
    end.

%% 23.2.3.17 Set.prototype.union — every element of this or other, this's elements
%% first (in this's order), then other's remaining elements (in other's order).
set_union(Recv, Args) ->
    require_set(Recv),
    Other = arg(Args, 0),
    set_from_elems(set_elems(Recv) ++ setlike_elems(Other)).

%% 23.2.3.9 Set.prototype.intersection — elements in both. Ordered as in the smaller
%% side: when |this| <= |other| iterate this, else iterate other.
set_intersection(Recv, Args) ->
    require_set(Recv),
    Other = arg(Args, 0),
    ThisElems = set_elems(Recv),
    case length(ThisElems) =< setlike_size(Other) of
        true ->
            set_from_elems([V || V <- ThisElems, setlike_has(Other, V)]);
        false ->
            set_from_elems([V || V <- setlike_elems(Other), set_has_elem(Recv, V)])
    end.

%% 23.2.3.5 Set.prototype.difference — elements of this not in other, in this's order.
set_difference(Recv, Args) ->
    require_set(Recv),
    Other = arg(Args, 0),
    set_from_elems([V || V <- set_elems(Recv), not setlike_has(Other, V)]).

%% 23.2.3.14 Set.prototype.symmetricDifference — elements in exactly one set: this's
%% elements not in other (this's order) followed by other's elements not in this
%% (other's order).
set_symmetric_difference(Recv, Args) ->
    require_set(Recv),
    Other = arg(Args, 0),
    InThisOnly = [V || V <- set_elems(Recv), not setlike_has(Other, V)],
    InOtherOnly = [V || V <- setlike_elems(Other), not set_has_elem(Recv, V)],
    set_from_elems(InThisOnly ++ InOtherOnly).

%% 23.2.3.7 Set.prototype.isDisjointFrom — true when this and other share no element.
set_is_disjoint_from(Recv, Args) ->
    require_set(Recv),
    Other = arg(Args, 0),
    ThisElems = set_elems(Recv),
    case length(ThisElems) =< setlike_size(Other) of
        true -> not lists:any(fun(V) -> setlike_has(Other, V) end, ThisElems);
        false -> not lists:any(fun(V) -> set_has_elem(Recv, V) end, setlike_elems(Other))
    end.

%% 23.2.3.11 Set.prototype.isSubsetOf — true when every element of this is in other.
set_is_subset_of(Recv, Args) ->
    require_set(Recv),
    Other = arg(Args, 0),
    ThisElems = set_elems(Recv),
    case length(ThisElems) > setlike_size(Other) of
        true -> false;
        false -> lists:all(fun(V) -> setlike_has(Other, V) end, ThisElems)
    end.

%% 23.2.3.12 Set.prototype.isSupersetOf — true when every element of other is in this.
set_is_superset_of(Recv, Args) ->
    require_set(Recv),
    Other = arg(Args, 0),
    case setlike_size(Other) > set_size(Recv) of
        true -> false;
        false -> lists:all(fun(V) -> set_has_elem(Recv, V) end, setlike_elems(Other))
    end.

make_map_iter(Recv, Kind) ->
    Cursor = cell_new(-1),
    gen_make(fun(_Arg) ->
        case cell_get(Cursor) of
            %% §23.1.5.2.1 step 4/step 11.b.iii: once the map's entries are
            %% exhausted the iterator sets [[Map]] to undefined and thereafter
            %% always reports done, so entries added AFTER exhaustion are never
            %% visited (mirrors make_set_iter's done-latching).
            done ->
                iter_result(undefined, true);
            Last ->
                case next_map_entry(Recv, Last) of
                    none ->
                        cell_set(Cursor, done),
                        iter_result(undefined, true);
                    {Seq, K, V} ->
                        cell_set(Cursor, Seq),
                        Val =
                            case Kind of
                                key -> K;
                                value -> V;
                                entry -> new_array([K, V])
                            end,
                        iter_result(Val, false)
                end
        end
    end).

make_set_iter(Recv, Kind) ->
    Cursor = cell_new(-1),
    gen_make(fun(_Arg) ->
        case cell_get(Cursor) of
            %% §23.2.5.2.1 step 8: once the iterator is exhausted it detaches
            %% from the set (its [[IteratedSet]] becomes undefined), so entries
            %% added AFTER the iterator is done are never visited.
            done ->
                iter_result(undefined, true);
            Last ->
                case next_set_entry(Recv, Last) of
                    none ->
                        cell_set(Cursor, done),
                        iter_result(undefined, true);
                    {Seq, V} ->
                        cell_set(Cursor, Seq),
                        Val =
                            case Kind of
                                value -> V;
                                entry -> new_array([V, V])
                            end,
                        iter_result(Val, false)
                end
        end
    end).

%% A fresh `{value: Val, done: Done}` result object for the iterator protocol.
iter_result(Val, Done) ->
    O = new_object(),
    set_prop(O, <<"value">>, Val),
    set_prop(O, <<"done">>, Done),
    O.

%% CreateArrayIterator (§23.1.5.1): a LIVE `{value, done}` cursor over an array cell,
%% driven by `.next()`. `Kind` selects the yield — `key` (index), `value` (element), or
%% `entry` (a fresh `[index, element]` array). The length is re-read on every step so an
%% array grown/shrunk mid-iteration is honoured (the iterator stops once the index
%% reaches the current length); holes read as `undefined`.
make_array_iter(Recv, Kind) ->
    Cursor = cell_new(0),
    gen_make(fun(_Arg) ->
        case cell_get(Cursor) of
            %% Once the index has caught up to the length the iterator LATCHES done
            %% (§23.1.5.2.1 sets [[ArrayIteratorNextIndex]] handling to completed), so
            %% elements pushed AFTER exhaustion are never visited.
            done ->
                iter_result(undefined, true);
            I ->
                {Len, Map} = arr_content(Recv),
                case I < Len of
                    false ->
                        cell_set(Cursor, done),
                        iter_result(undefined, true);
                    true ->
                        cell_set(Cursor, I + 1),
                        Val =
                            case Kind of
                                key -> I;
                                value -> maps:get(I, Map, undefined);
                                entry ->
                                    new_array([I, maps:get(I, Map, undefined)])
                            end,
                        iter_result(Val, false)
                end
        end
    end).

%% CreateStringIterator (§22.1.5.1): a LIVE `{value, done}` cursor over a string that
%% yields each Unicode code point as a one-code-point string (surrogate pairs stay
%% whole — this code-point model has no lone surrogates). Backing store: the remaining
%% code-point list in a cell.
make_string_iter(Str) ->
    Cursor = cell_new(cps(Str)),
    gen_make(fun(_Arg) ->
        case cell_get(Cursor) of
            [] ->
                iter_result(undefined, true);
            [C | Rest] ->
                cell_set(Cursor, Rest),
                iter_result(from_cps([C]), false)
        end
    end).

%% A Map cell's entries as a list of fresh `[key, value]` arrays in insertion order
%% (ascending Seq). The keys are the SameValueZero-normalized keys the Map stores
%% (matching Map.prototype.entries / .forEach). A non-Map yields the empty list.
map_entry_arrays(Recv) ->
    case cell_tag(Recv) of
        {js_map, _, D} ->
            Sorted = lists:sort(
                fun({_, {A, _}}, {_, {B, _}}) -> A =< B end, maps:to_list(D)
            ),
            [new_array([K, V]) || {K, {_, V}} <- Sorted];
        _ ->
            []
    end.

%% `x[Symbol.iterator]` — the built-in iterator-producing method for a built-in
%% iterable, as a zero-argument BEAM fun (so `x[Symbol.iterator]()` applies it to
%% produce a fresh iterator). Arrays/Sets/Maps/strings each return a fresh cursor;
%% an iterator object (a generator cell, e.g. the result of `.values()`) returns
%% ITSELF, since an iterator's own `[Symbol.iterator]` is the identity (§27.1.5.1.1).
%% Any non-iterable receiver has no such method — `undefined`.
builtin_iter_fn(Recv) when is_binary(Recv) ->
    fun() -> make_string_iter(Recv) end;
builtin_iter_fn(Recv) when is_reference(Recv) ->
    case cell_tag(Recv) of
        {js_array, _, _} -> fun() -> make_array_iter(Recv, value) end;
        {js_set, _, _} -> fun() -> make_set_iter(Recv, value) end;
        {js_map, _, _} -> fun() -> make_map_iter(Recv, entry) end;
        {js_gen, _} -> fun() -> Recv end;
        _ -> undefined
    end;
builtin_iter_fn(_) ->
    undefined.

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

%% RegExp(pattern, flags) constructor semantics — RegExpInitialize (§22.2.3.1 /
%% §22.2.1.1). Resolves the effective pattern P and flags F, then compiles them
%% like a `/P/F` literal:
%%   * If `Pattern` is already a RegExp, reuse its original source; the flags are
%%     `Pattern`'s own when `Flags` is `undefined`, otherwise the supplied `Flags`.
%%   * Otherwise an `undefined` pattern or `undefined` flags becomes the empty
%%     string (per steps "If pattern is undefined, let P be the empty String")
%%     and any other value is ToString'd.
%% An empty resolved pattern is stored as the escaped source `"(?:)"` so that
%% `re.source` reports `"(?:)"` (EscapeRegExpPattern, §22.2.6.13.1) rather than
%% the empty string, while still compiling to a pattern that matches the empty
%% string. `Pattern`/`Flags` arrive as raw JS values from the constructor call.
regex_construct(Pattern, Flags) ->
    {P, F} =
        case is_regex(Pattern) of
            true ->
                {_MP, PF, PS} = regex_content(Pattern),
                F1 =
                    case Flags of
                        undefined -> PF;
                        _ -> to_string(Flags)
                    end,
                {PS, F1};
            false ->
                P1 =
                    case Pattern of
                        undefined -> <<>>;
                        _ -> to_string(Pattern)
                    end,
                F1 =
                    case Flags of
                        undefined -> <<>>;
                        _ -> to_string(Flags)
                    end,
                {P1, F1}
        end,
    Source =
        case P of
            <<>> -> <<"(?:)">>;
            _ -> P
        end,
    new_regex(Source, F).

re_opts(Flags) ->
    %% `dupnames` permits duplicate named capture groups, which ES2025 allows
    %% when the groups sit in mutually exclusive alternatives — e.g.
    %% `(?<x>a)|(?<x>b)` (§22.2.1.1, GroupSpecifiersThatMatch). PCRE rejects them
    %% without this option; `re:inspect/namelist` and `all_names` capture still
    %% report a single name bound to whichever alternative participated.
    Base = [unicode, dupnames],
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

%% re.test(str) → JS boolean. Per §22.2.6.15 this is `RegExpExec(R, S) != null`,
%% so — like exec — it advances `lastIndex` for a global/sticky regex.
regex_test(Re, Str) ->
    regex_exec(Re, Str) =/= null.

%% RegExp.prototype.exec(string) — RegExpBuiltinExec (§22.2.7.2).
%%
%% Runs the compiled pattern against ToString(string), honouring the regex's
%% `lastIndex` (only consulted for global/sticky regexes, else the search starts
%% at 0) and the sticky (`y`) flag (which anchors the match at that position).
%% Returns `null` on no match, otherwise a JS array `[matched | captures]` with
%% own properties `index` (code-point offset of the match), `input` (the subject
%% string), and `groups` (an object of named captures, or `undefined` when the
%% pattern has none). Unmatched optional captures appear as `undefined`. For a
%% global or sticky regex `lastIndex` is updated to the code-point index just past
%% the match (or reset to 0 when the match fails or `lastIndex` is out of range).
%% Indices are code-point based to match this runtime's string model.
regex_exec(Re, Str) ->
    {MP, Flags, Src} = regex_content(Re),
    S = to_string(Str),
    Global = has_flag(Flags, $g),
    Sticky = has_flag(Flags, $y),
    Track = Global orelse Sticky,
    Start =
        case Track of
            true -> regex_last_index_int(Re);
            false -> 0
        end,
    case re_exec_cp(MP, S, Start, Sticky, regex_group_count(Src)) of
        nomatch ->
            case Track of
                true -> regex_set_last_index(Re, 0);
                false -> ok
            end,
            null;
        {match, StartCp, EndCp, [Whole | Caps], Groups} ->
            case Track of
                true -> regex_set_last_index(Re, EndCp);
                false -> ok
            end,
            Arr = new_array([Whole | Caps]),
            set_prop(Arr, <<"index">>, StartCp),
            set_prop(Arr, <<"input">>, S),
            set_prop(Arr, <<"groups">>, Groups),
            Arr
    end.

%% Core matcher shared by exec/test/match/search/split. Runs `MP` against `S`
%% starting at code-point index `StartCp`; when `Sticky` is true the match must
%% begin exactly at `StartCp` (anchored). `NG` is the pattern's capturing-group
%% count — captures are requested by explicit number `[0..NG]` so that trailing
%% non-participating groups (which `re`'s `all` spec drops) still appear, as
%% `undefined`, giving the exec array its spec-mandated length. Returns `nomatch`,
%% or `{match, StartCp, EndCp, [Whole | Caps], Groups}` where the offsets are
%% code-point indices, each capture is a binary or `undefined`, and `Groups` is a
%% named-capture object or `undefined`. `StartCp` past the end yields `nomatch`.
re_exec_cp(MP, S, StartCp, Sticky, NG) ->
    Cps = cps(S),
    Len = length(Cps),
    case StartCp > Len of
        true ->
            nomatch;
        false ->
            ByteOff = byte_size(from_cps(lists:sublist(Cps, 1, StartCp))),
            Anchor =
                case Sticky of
                    true -> [anchored];
                    false -> []
                end,
            Spec = [{offset, ByteOff}, {capture, lists:seq(0, NG), index} | Anchor],
            case re:run(S, MP, Spec) of
                nomatch ->
                    nomatch;
                {match, [{MSB, MLB} | GroupOffs]} ->
                    StartCp2 = length(cps(binary:part(S, 0, MSB))),
                    EndCp2 = length(cps(binary:part(S, 0, MSB + MLB))),
                    Bins = [group_binary(S, {MSB, MLB}) | [group_binary(S, G) || G <- GroupOffs]],
                    Groups = regex_named_groups(MP, S, ByteOff, Anchor),
                    {match, StartCp2, EndCp2, Bins, Groups}
            end
    end.

%% A capture's byte {offset,length} → its substring, or `undefined` for an
%% unmatched optional group (which `re` reports with a negative offset).
group_binary(_S, {Off, _Len}) when Off < 0 -> undefined;
group_binary(S, {Off, Len}) -> binary:part(S, Off, Len).

%% Count the capturing groups in a regex source. Skips escaped characters and
%% character classes `[...]`, and treats `(?…)` as non-capturing EXCEPT a named
%% group `(?<name>…)` (distinguished from lookbehind `(?<=`/`(?<!`). Used to size
%% the numbered-capture request so trailing optional groups are not dropped.
regex_group_count(Src) -> rgc(Src, 0, false).

rgc(<<>>, N, _InClass) ->
    N;
rgc(<<$\\, _C, R/binary>>, N, InClass) ->
    rgc(R, N, InClass);
rgc(<<$[, R/binary>>, N, false) ->
    rgc(R, N, true);
rgc(<<$], R/binary>>, N, true) ->
    rgc(R, N, false);
rgc(<<_C, R/binary>>, N, true) ->
    rgc(R, N, true);
rgc(<<$(, $?, $<, C, R/binary>>, N, false) when C =/= $=, C =/= $! ->
    rgc(<<C, R/binary>>, N + 1, false);
rgc(<<$(, $?, R/binary>>, N, false) ->
    rgc(R, N, false);
rgc(<<$(, R/binary>>, N, false) ->
    rgc(R, N + 1, false);
rgc(<<_C, R/binary>>, N, false) ->
    rgc(R, N, false).

%% The `groups` object for a match: `undefined` when the pattern has no named
%% captures, otherwise an object mapping each `(?<name>…)` name to its captured
%% substring (or `undefined` when that named group did not participate).
regex_named_groups(MP, S, ByteOff, Anchor) ->
    case re:inspect(MP, namelist) of
        {namelist, []} ->
            undefined;
        {namelist, Names} ->
            Obj = new_object(),
            case re:run(S, MP, [{offset, ByteOff}, {capture, all_names, index} | Anchor]) of
                {match, Offs} ->
                    lists:foreach(
                        fun({Name, Off}) -> define_data(Obj, Name, group_binary(S, Off)) end,
                        lists:zip(Names, Offs)
                    );
                _ ->
                    ok
            end,
            Obj
    end.

%% ── regex lastIndex (a per-object mutable slot) ──────────
%% Held in a separate process-dictionary entry keyed by the regex cell, so it
%% never appears among enumerable properties.
regex_last_index_raw(Re) ->
    case erlang:get({js_regex_li, Re}) of
        undefined -> 0;
        V -> V
    end.

regex_set_last_index(Re, V) ->
    erlang:put({js_regex_li, Re}, V).

%% ToLength(R.lastIndex) as a non-negative integer (§7.1.20). NaN/undefined → 0;
%% +Infinity → a value past any string so the match fails, per spec.
regex_last_index_int(Re) ->
    case coerce_num(regex_last_index_raw(Re)) of
        nan -> 0;
        neg_inf -> 0;
        inf -> 1 bsl 53;
        N -> max(0, trunc(as_float(N)))
    end.

%% re.source / re.flags.
regex_source(Re) ->
    {_MP, _F, S} = regex_content(Re),
    S.
regex_flags(Re) ->
    {_MP, F, _S} = regex_content(Re),
    canonical_flags(F).

%% Serialise a regex's flag set in the canonical order mandated by the
%% `RegExp.prototype.flags` getter (§22.2.6.4): d, g, i, m, s, u, v, y — one
%% code unit per flag actually present, independent of the order the flags were
%% supplied at construction. `Flags` is the regex's OriginalFlags binary; the
%% result is a binary containing only the recognised flag characters that are
%% set, always in the fixed order above.
canonical_flags(Flags) ->
    Order = [$d, $g, $i, $m, $s, $u, $v, $y],
    list_to_binary([C || C <- Order, has_flag(Flags, C)]).

%% String.prototype.match(re) (§22.2.6.8 via RegExp.prototype[@@match]). A
%% non-regex `Re` is coerced to `new RegExp(Re)`. For a global regex: reset
%% `lastIndex`, collect every matched substring (advancing past empty matches),
%% returning an array of substrings or `null` when there is no match. Otherwise
%% delegate to `exec`, so the result is the exec array (with index/input/groups)
%% or `null`.
str_match(Str, Re0) ->
    Re = ensure_regex(Re0),
    {MP, Flags, _S} = regex_content(Re),
    case has_flag(Flags, $g) of
        true ->
            regex_set_last_index(Re, 0),
            case regex_match_loop(MP, to_string(Str), 0, []) of
                [] -> null;
                Acc -> new_array(lists:reverse(Acc))
            end;
        false ->
            regex_exec(Re, Str)
    end.

%% Accumulate every whole-match substring of a global match, advancing one code
%% point past an empty match so the loop terminates (per AdvanceStringIndex). Only
%% the whole match is needed, so captures are not requested (NG = 0).
regex_match_loop(MP, S, Pos, Acc) ->
    case re_exec_cp(MP, S, Pos, false, 0) of
        nomatch ->
            Acc;
        {match, StartCp, EndCp, [Whole | _], _Groups} ->
            Next =
                case EndCp =:= StartCp of
                    true -> EndCp + 1;
                    false -> EndCp
                end,
            regex_match_loop(MP, S, Next, [Whole | Acc])
    end.

%% String.prototype.search(re) (§22.2.6.11). A non-regex `Re` is coerced to
%% `new RegExp(Re)`. Ignores `lastIndex`/global (always searches from the start)
%% and returns the code-point index of the first match, or -1 when there is none.
str_search(Str, Re0) ->
    {MP, _Flags, _S} = as_regex(Re0),
    case re_exec_cp(MP, to_string(Str), 0, false, 0) of
        nomatch -> -1;
        {match, StartCp, _EndCp, _Bins, _Groups} -> StartCp
    end.

%% Coerce a value used where a regex is expected (`str.match`/`search`/`split`
%% with a non-regex argument): a regex passes through as a cell, anything else is
%% compiled via `new RegExp(ToString(v))` (`undefined` → the empty pattern).
ensure_regex(V) ->
    case is_regex(V) of
        true -> V;
        false -> new_regex(regex_arg_pat(V), <<>>)
    end.

as_regex(V) -> regex_content(ensure_regex(V)).

regex_arg_pat(undefined) -> <<>>;
regex_arg_pat(V) -> to_string(V).

%% String.prototype.replace with a regex search (§22.2.6.11 RegExp[@@replace]).
%%
%% Replaces the first match (or every match, if the regex is global). `Repl` is
%% either a replacement template string — expanded by GetSubstitution (`$$`,
%% `$&`, `` $` ``, `$'`, `$n`/`$nn` numbered captures, `$<name>` named captures) —
%% or a function, which is called with `(matched, cap1…capN, position, string)`
%% and whose result (ToString'd) is spliced in. Empty matches advance one code
%% point (so a global empty-matching pattern terminates). Indices are code-point
%% based; a global regex has its `lastIndex` reset to 0 first.
str_replace_regex(Str, Re, Repl) ->
    {MP, Flags, Src} = regex_content(Re),
    NG = regex_group_count(Src),
    S = to_string(Str),
    Global = has_flag(Flags, $g),
    case Global of
        true -> regex_set_last_index(Re, 0);
        false -> ok
    end,
    Cps = cps(S),
    Size = length(Cps),
    IsFn = is_function(Repl),
    replace_loop(MP, S, Cps, Size, 0, 0, Global, Repl, IsFn, NG, <<>>).

%% Walk the subject replacing matches. `Pos` is the next search position and
%% `Copied` the code-point index up to which `S` has already been emitted into
%% `Acc`; both are code-point indices. `NG` sizes the capture request.
replace_loop(MP, S, Cps, Size, Pos, Copied, Global, Repl, IsFn, NG, Acc) ->
    case re_exec_cp(MP, S, Pos, false, NG) of
        nomatch ->
            <<Acc/binary, (cp_sub(Cps, Copied, Size))/binary>>;
        {match, StartCp, EndCp, [Whole | Caps], Groups} ->
            Between = cp_sub(Cps, Copied, StartCp),
            Replacement =
                case IsFn of
                    true ->
                        to_string(call_cb(Repl, [Whole | Caps] ++ [StartCp, S]));
                    false ->
                        gsub(to_string(Repl), Whole, S, StartCp, Caps, Groups)
                end,
            Acc1 = <<Acc/binary, Between/binary, Replacement/binary>>,
            case Global of
                false ->
                    <<Acc1/binary, (cp_sub(Cps, EndCp, Size))/binary>>;
                true ->
                    Next =
                        case EndCp =:= StartCp of
                            true -> EndCp + 1;
                            false -> EndCp
                        end,
                    replace_loop(MP, S, Cps, Size, Next, EndCp, Global, Repl, IsFn, NG, Acc1)
            end
    end.

%% GetSubstitution (§22.2.6.11.1): expand a replacement template against one
%% match. `Matched` is the whole match, `S` the subject, `Position` the match's
%% code-point start, `Captures` the numbered captures (each a binary or
%% `undefined`), and `Named` the named-captures object (or `undefined`).
gsub(Template, Matched, S, Position, Captures, Named) ->
    Cps = cps(S),
    Size = length(Cps),
    Prefix = cp_sub(Cps, 0, Position),
    Suffix = cp_sub(Cps, Position + length(cps(Matched)), Size),
    Ctx = {Matched, Prefix, Suffix, Captures, length(Captures), Named},
    gsub_scan(Template, Ctx, <<>>).

gsub_scan(<<>>, _Ctx, Acc) ->
    Acc;
gsub_scan(<<$$, Rest/binary>>, Ctx, Acc) ->
    {Sub, Rest2} = gsub_dollar(Rest, Ctx),
    gsub_scan(Rest2, Ctx, <<Acc/binary, Sub/binary>>);
gsub_scan(<<Ch, Rest/binary>>, Ctx, Acc) ->
    gsub_scan(Rest, Ctx, <<Acc/binary, Ch>>).

%% Resolve the substitution that follows a `$`, returning `{Replacement, Rest}`.
%% An unrecognised `$x` (or a trailing `$`) is a literal `$`, with `x` left to be
%% rescanned as ordinary text.
gsub_dollar(<<$$, R/binary>>, _Ctx) ->
    {<<$$>>, R};
gsub_dollar(<<$&, R/binary>>, {M, _P, _S, _C, _L, _N}) ->
    {M, R};
gsub_dollar(<<$`, R/binary>>, {_M, P, _S, _C, _L, _N}) ->
    {P, R};
gsub_dollar(<<$', R/binary>>, {_M, _P, Suf, _C, _L, _N}) ->
    {Suf, R};
gsub_dollar(<<$<, R/binary>>, Ctx) ->
    gsub_named(R, Ctx);
gsub_dollar(<<D, _/binary>> = In, Ctx) when D >= $0, D =< $9 ->
    gsub_digits(In, Ctx);
gsub_dollar(R, _Ctx) ->
    {<<$$>>, R}.

%% `$n` / `$nn` numbered capture. Prefers a two-digit index when it names a real
%% capture; otherwise falls back to one digit; `$0` and out-of-range indices are
%% literal (the `$` is emitted and the digits are rescanned as text).
gsub_digits(<<D1, D2, R/binary>>, {_M, _P, _S, Caps, Len, _N})
    when D1 >= $0, D1 =< $9, D2 >= $0, D2 =< $9 ->
    N2 = (D1 - $0) * 10 + (D2 - $0),
    N1 = D1 - $0,
    case in_range(N2, Len) of
        true -> {cap_str(Caps, N2), R};
        false ->
            case in_range(N1, Len) of
                true -> {cap_str(Caps, N1), <<D2, R/binary>>};
                false -> {<<$$>>, <<D1, D2, R/binary>>}
            end
    end;
gsub_digits(<<D1, R/binary>>, {_M, _P, _S, Caps, Len, _N}) when D1 >= $0, D1 =< $9 ->
    N1 = D1 - $0,
    case in_range(N1, Len) of
        true -> {cap_str(Caps, N1), R};
        false -> {<<$$>>, <<D1, R/binary>>}
    end.

in_range(N, Len) -> N >= 1 andalso N =< Len.

%% The n-th capture (1-based) as a string; an unmatched (`undefined`) capture
%% substitutes the empty string.
cap_str(Caps, N) ->
    case lists:nth(N, Caps) of
        undefined -> <<>>;
        B -> B
    end.

%% `$<name>` named-capture substitution. With no named captures at all the
%% literal `$<` is kept; an unterminated `$<…` (no `>`) is likewise literal.
gsub_named(R, {_M, _P, _S, _C, _L, undefined}) ->
    {<<$$, $<>>, R};
gsub_named(R, {_M, _P, _S, _C, _L, Named}) ->
    case binary:split(R, <<">">>) of
        [Name, Rest] ->
            case get_prop(Named, Name) of
                undefined -> {<<>>, Rest};
                V -> {to_string(V), Rest}
            end;
        _ ->
            {<<$$, $<>>, R}
    end.

%% String.prototype.split with a regex separator (§22.2.6.14 RegExp[@@split]).
%% Splits `Str` at every match of the separator, using a sticky (anchored) probe
%% at each position so match boundaries follow JS semantics: a zero-width match
%% at the current split point is skipped, and any capturing groups in the
%% separator contribute their captures (or `undefined`) between the surrounding
%% pieces. Indices are code-point based. `Re` may be a non-regex value (coerced).
str_split_regex(Str, Re) ->
    {MP, _Flags, Src} = as_regex(Re),
    NG = regex_group_count(Src),
    S = to_string(Str),
    Cps = cps(S),
    Size = length(Cps),
    case Size of
        0 ->
            %% An empty subject yields `[]` if the separator matches "", else `[""]`.
            case re_exec_cp(MP, S, 0, true, NG) of
                nomatch -> new_array([S]);
                _ -> new_array([])
            end;
        _ ->
            new_array(split_loop(MP, S, Cps, Size, 0, 0, NG, []))
    end.

%% Scan for separator matches. `P` is the start of the pending piece and `Q` the
%% current probe position (both code-point indices); `Acc` holds the output
%% elements in reverse. On reaching the end, append the trailing piece `S[P..]`.
split_loop(_MP, _S, Cps, Size, P, Q, _NG, Acc) when Q >= Size ->
    lists:reverse([cp_sub(Cps, P, Size) | Acc]);
split_loop(MP, S, Cps, Size, P, Q, NG, Acc) ->
    case re_exec_cp(MP, S, Q, true, NG) of
        nomatch ->
            split_loop(MP, S, Cps, Size, P, Q + 1, NG, Acc);
        {match, _StartCp, EndCp, [_Whole | Caps], _Groups} ->
            E = min(EndCp, Size),
            case E =:= P of
                %% Zero-width match at the current split point: skip it.
                true ->
                    split_loop(MP, S, Cps, Size, P, Q + 1, NG, Acc);
                false ->
                    Piece = cp_sub(Cps, P, Q),
                    Acc1 = lists:reverse([Piece | Caps]) ++ Acc,
                    split_loop(MP, S, Cps, Size, E, E, NG, Acc1)
            end
    end.

%% The substring of a code-point list over the half-open code-point range
%% [From, To) as a binary.
cp_sub(Cps, From, To) -> from_cps(lists:sublist(Cps, From + 1, max(0, To - From))).

%% Apply a JS function value to a runtime-length argument list (behind call spread
%% `f(...args)`); arity-adaptive like a callback.
apply_fn(F, Args) when is_function(F) -> call_cb(F, Args);
apply_fn(F, _Args) -> not_callable(F).

%% Function.prototype.call(thisArg, ...args) — §20.2.3.3. This compiler models a
%% plain function as a bare BEAM closure with no bound receiver, so `thisArg` (the
%% head of `AllArgs`) is ignored and the target is applied to the remaining
%% arguments (arity-adaptive via call_cb: missing params default to `undefined`,
%% extras are dropped). A non-function receiver delegates to a same-named user
%% `call` method on the object (so `obj.call(...)` still reaches a user method).
func_call(F, AllArgs) when is_function(F) ->
    Rest =
        case AllArgs of
            [] -> [];
            [_This | R] -> R
        end,
    call_cb(F, Rest);
func_call(Recv, AllArgs) ->
    delegate(Recv, <<"call">>, AllArgs).

%% Function.prototype.apply(thisArg, argArray) — §20.2.3.1. Ignores `thisArg` (see
%% func_call) and applies the target to the elements of `argArray`. Per step 3, a
%% null/undefined `argArray` means the empty argument list. A non-function receiver
%% delegates to a same-named user `apply` method. `AllArgs` is the raw call argument
%% list `[thisArg, argArray | _]`.
func_apply(F, AllArgs) when is_function(F) ->
    ArgArray =
        case AllArgs of
            [_This, AA | _] -> AA;
            _ -> undefined
        end,
    call_cb(F, apply_arg_list(ArgArray));
func_apply(Recv, AllArgs) ->
    delegate(Recv, <<"apply">>, AllArgs).

%% Function.prototype.bind(thisArg, ...boundArgs) — §20.2.3.2. Returns a new
%% function (a "bound function exotic object") that, when called, prepends the
%% saved `boundArgs` to the call's own arguments and applies the target. This
%% compiler models a plain function as a bare BEAM closure with no bound
%% receiver, so `thisArg` (the head of `AllArgs`) is DROPPED — matching the
%% documented treatment of `this` for call/apply; only the partial-application
%% (bound-argument) behavior is modelled. The returned closure's declared arity
%% is the target's [[Length]] minus the number of bound arguments, floored at 0
%% (the spec's SetFunctionLength result) so that a caller supplying the
%% remaining expected arguments forwards them all; extra trailing arguments are
%% dropped by arity-fitting, exactly as a direct call would. The bound function
%% NEVER carries the target's own properties (`length`/`name`/`prototype`) —
%% those need a full function-object model this compiler does not have. A
%% non-function receiver delegates to a same-named user `bind` method.
func_bind(F, AllArgs) when is_function(F) ->
    Bound =
        case AllArgs of
            [] -> [];
            [_This | Rest] -> Rest
        end,
    {arity, TargetArity} = erlang:fun_info(F, arity),
    Remaining = max(0, TargetArity - length(Bound)),
    make_bound(F, Bound, Remaining);
func_bind(Recv, AllArgs) ->
    delegate(Recv, <<"bind">>, AllArgs).

%% Build the bound-function closure of arity `R` (the remaining parameter count).
%% BEAM closures are fixed-arity, so we emit one clause per small arity; each
%% forwards its own arguments after the captured `Bound` list to `call_cb`
%% (which arity-fits the concatenation to the target). Arities above the
%% enumerated range fall back to an arity-0 closure that still applies the bound
%% arguments (a call supplying that many extra positional arguments to a bound
%% function is vanishingly rare in practice).
make_bound(F, Bound, 0) ->
    fun() -> call_cb(F, Bound) end;
make_bound(F, Bound, 1) ->
    fun(A1) -> call_cb(F, Bound ++ [A1]) end;
make_bound(F, Bound, 2) ->
    fun(A1, A2) -> call_cb(F, Bound ++ [A1, A2]) end;
make_bound(F, Bound, 3) ->
    fun(A1, A2, A3) -> call_cb(F, Bound ++ [A1, A2, A3]) end;
make_bound(F, Bound, 4) ->
    fun(A1, A2, A3, A4) -> call_cb(F, Bound ++ [A1, A2, A3, A4]) end;
make_bound(F, Bound, 5) ->
    fun(A1, A2, A3, A4, A5) -> call_cb(F, Bound ++ [A1, A2, A3, A4, A5]) end;
make_bound(F, Bound, 6) ->
    fun(A1, A2, A3, A4, A5, A6) -> call_cb(F, Bound ++ [A1, A2, A3, A4, A5, A6]) end;
make_bound(F, Bound, _) ->
    fun() -> call_cb(F, Bound) end.

%% CreateListFromArrayLike for Function.prototype.apply: null/undefined → no args;
%% otherwise the array's elements in order. Exported so the JS lowering can turn a
%% `f.apply(thisArg, argArray)` on a user function into an `apply_fn` over the
%% `this`-baked callback closure (wave 14).
apply_arg_list(undefined) -> [];
apply_arg_list(null) -> [];
apply_arg_list(Arr) -> array_to_list(Arr).

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
        %% Spreading a Set yields its elements in insertion order (the Set is an
        %% iterable whose iterator is Set.prototype.values).
        {js_set, _, _} -> array_push(Target, set_elems(Value));
        %% Spreading a Map yields its `[key, value]` entries in insertion order (the
        %% Map's default iterator is Map.prototype.entries).
        {js_map, _, _} -> array_push(Target, map_entry_arrays(Value));
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

%% map(fn) — per ES §22.1.3.19: visit every index k in [0, len) where the array
%% currently HAS an own element (holes are NOT visited and are PRESERVED as holes
%% in the result), re-reading the live array each step so a callback that mutates
%% or deletes later indices is observed. `len` is captured at entry, so elements
%% the callback adds beyond the original length are never visited. The result has
%% the same length as the source. Callback: (element, index, array).
array_map(Recv, Fn) ->
    case cell_tag(Recv) of
        {js_gen, _} ->
            iter_map(Recv, Fn);
        _ ->
            {Len, _Map} = arr_content(Recv),
            cell_new({js_array, Len, amap(Fn, Recv, 0, Len, #{})})
    end.
amap(_, _, K, Len, Acc) when K >= Len -> Acc;
amap(Fn, Arr, K, Len, Acc) ->
    case arr_index(Arr, K) of
        {ok, X} -> amap(Fn, Arr, K + 1, Len, maps:put(K, call_cb(Fn, [X, K, Arr]), Acc));
        error -> amap(Fn, Arr, K + 1, Len, Acc)
    end.

%% filter(fn) — per ES §22.1.3.7: visit only present elements (holes skipped, not
%% visited), live re-read each step, iteration bounded by the entry length. The
%% result is a DENSE array of the kept elements. Callback: (element, index, array).
array_filter(Recv, Fn) ->
    case cell_tag(Recv) of
        {js_gen, _} ->
            iter_filter(Recv, Fn);
        _ ->
            {Len, _Map} = arr_content(Recv),
            new_array(afilter(Fn, Recv, 0, Len))
    end.
afilter(_, _, K, Len) when K >= Len -> [];
afilter(Fn, Arr, K, Len) ->
    case arr_index(Arr, K) of
        {ok, X} ->
            case truthy(call_cb(Fn, [X, K, Arr])) of
                1 -> [X | afilter(Fn, Arr, K + 1, Len)];
                0 -> afilter(Fn, Arr, K + 1, Len)
            end;
        error ->
            afilter(Fn, Arr, K + 1, Len)
    end.

%% forEach(fn) — per ES §22.1.3.12: call the callback once for each present element
%% (holes are skipped via a per-step HasProperty check), re-reading the live array
%% each step and bounding iteration by the length captured at entry. Returns
%% undefined. Callback: (element, index, array).
array_foreach(Recv, Fn) ->
    {Len, _Map} = arr_content(Recv),
    aforeach(Fn, Recv, 0, Len),
    undefined.
aforeach(_, _, K, Len) when K >= Len -> ok;
aforeach(Fn, Arr, K, Len) ->
    case arr_index(Arr, K) of
        {ok, X} -> call_cb(Fn, [X, K, Arr]);
        error -> ok
    end,
    aforeach(Fn, Arr, K + 1, Len).

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
    case cell_tag(Recv) of
        {js_gen, _} ->
            iter_reduce(Recv, Fn, Init);
        _ ->
            {Len, _Map} = arr_content(Recv),
            areduce(Fn, Recv, 0, Len, Init)
    end.
areduce(_, _, K, Len, Acc) when K >= Len -> Acc;
areduce(Fn, Arr, K, Len, Acc) ->
    case arr_index(Arr, K) of
        {ok, X} -> areduce(Fn, Arr, K + 1, Len, call_cb(Fn, [Acc, X, K, Arr]));
        error -> areduce(Fn, Arr, K + 1, Len, Acc)
    end.

%% reduce(fn) — no seed: the first present element seeds the accumulator and the
%% fold continues after it. An array with no present element in range → TypeError.
array_reduce1(Recv, Fn) ->
    case cell_tag(Recv) of
        {js_gen, _} -> iter_reduce1(Recv, Fn);
        _ -> array_reduce1_arr(Recv, Fn)
    end.
array_reduce1_arr(Recv, Fn) ->
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
    case cell_tag(Recv) of
        {js_gen, _} ->
            iter_some(Recv, Fn);
        _ ->
            {Len, _Map} = arr_content(Recv),
            asome(Fn, Recv, 0, Len)
    end.
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
    case cell_tag(Recv) of
        {js_gen, _} ->
            iter_every(Recv, Fn);
        _ ->
            {Len, _Map} = arr_content(Recv),
            aevery(Fn, Recv, 0, Len)
    end.
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
    case cell_tag(Recv) of
        {js_gen, _} ->
            iter_find(Recv, Fn);
        _ ->
            {Len, _Map} = arr_content(Recv),
            afind(Fn, Recv, 0, Len)
    end.
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
%% Reject a non-callable callback with a TypeError, per the `If IsCallable(fn) is
%% false, throw a TypeError` step that array iteration methods run BEFORE visiting
%% any element (so an empty array still throws). Returns `ok` when `Fn` is callable.
require_callable(Fn) ->
    case is_function(Fn) of
        true -> ok;
        false -> not_callable(Fn)
    end.

array_flat_map(Recv, Fn) ->
    {Len, _Map} = arr_content(Recv),
    require_callable(Fn),
    new_array(aflatmap(Fn, Recv, 0, Len)).
aflatmap(_, _, K, Len) when K >= Len -> [];
aflatmap(Fn, Arr, K, Len) ->
    case arr_index(Arr, K) of
        {ok, X} -> flat_one(call_cb(Fn, [X, K, Arr])) ++ aflatmap(Fn, Arr, K + 1, Len);
        error -> aflatmap(Fn, Arr, K + 1, Len)
    end.

%% arr.findLast(fn) / findLastIndex(fn) — like find/findIndex from the end:
%% visit every index from Len-1 down to 0 (a hole reads as undefined), live re-read.
array_find_last(Recv, Fn) ->
    {Len, _Map} = arr_content(Recv),
    require_callable(Fn),
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
    require_callable(Fn),
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
    {Len, _Map} = arr_content(Recv),
    Cap = last_idx_from(From, Len),
    alast_idx(Recv, min(Cap, Len - 1), X).

%% lastIndexOf(searchElement) with NO fromIndex argument (§22.1.3.17 step: "If
%% fromIndex is present … else let n be len - 1"). This is DISTINCT from an
%% explicit `undefined` fromIndex: an absent argument scans from the last index,
%% whereas a present `undefined` coerces via ToIntegerOrInfinity to 0 and scans
%% only index 0. Lowering routes the arity-1 (and no-arg) call here so the two
%% cases are not conflated. A string receiver keeps the String.prototype path.
array_last_index_of_end(Recv, X) when is_binary(Recv) ->
    str_last_index_of(Recv, X, undefined);
array_last_index_of_end(Recv, X) ->
    {Len, _Map} = arr_content(Recv),
    alast_idx(Recv, Len - 1, X).

%% Resolve a PRESENT fromIndex argument to the starting scan index for
%% lastIndexOf. Per §22.1.3.17, `undefined` (and any NaN) is ToIntegerOrInfinity
%% → 0; -Infinity yields -1 (empty scan); a negative index counts from the end.
%% The absent-argument case is handled separately by array_last_index_of_end/2.
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

%% Per ES §22.1.3.17, lastIndexOf scans from `K` downward and visits only
%% indices the array HAS (holes skipped via HasProperty, so
%% `[0, , 2].lastIndexOf(undefined)` is -1), re-reading the live array each step.
alast_idx(_Arr, K, _X) when K < 0 -> -1;
alast_idx(Arr, K, X) ->
    case arr_index(Arr, K) of
        {ok, E} ->
            case strict_eq(E, X) of
                1 -> K;
                0 -> alast_idx(Arr, K - 1, X)
            end;
        error ->
            alast_idx(Arr, K - 1, X)
    end.

%% recv.toString() — a user-defined `toString` method (a function property) wins;
%% otherwise the default ToString. A Date cell has no property map, so it is resolved
%% directly to its string form (§21.4.4.41): reading a property off it via `get_prop`
%% would raise a TypeError rather than fall through to the default ToString.
to_string_dispatch(Recv) when is_reference(Recv) ->
    case cell_tag(Recv) of
        {js_date, Ms} ->
            date_to_string(Ms);
        _ ->
            case get_prop(Recv, <<"toString">>) of
                F when is_function(F) -> F();
                _ -> to_string(Recv)
            end
    end;
%% `sym.toString()` — SymbolDescriptiveString (§20.4.3.3): "Symbol(" + desc + ")",
%% desc defaulting to the empty string when the Symbol has no description.
to_string_dispatch({js_symbol, _, _} = Sym) ->
    symbol_to_string(Sym);
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
%% exponent (`e+2`), so the exponent is de-padded afterwards. Per the spec the sign
%% prefix is added only when `x < 0`; negative zero is not `< 0`, so it renders
%% without a leading "-" — Erlang would otherwise emit "-0…", so ±0 is normalised.
num_to_exponential(N, D) ->
    case coerce_num(this_number_value(N)) of
        nan ->
            <<"NaN">>;
        inf ->
            <<"Infinity">>;
        neg_inf ->
            <<"-Infinity">>;
        Num ->
            F = as_float(Num),
            case D of
                %% fractionDigits undefined ONLY → shortest round-tripping form. The
                %% spec's undefined branch breaks ties toward the even digit, which
                %% matches Erlang's {scientific,_} rounding, so this path is unchanged.
                %% Note: a specified argument that coerces to NaN (e.g. NaN itself, or a
                %% non-numeric string) is NOT undefined — it takes the specified path
                %% below, where ToIntegerOrInfinity(NaN) = 0 (see `to_frac_digits`).
                undefined ->
                    fix_exp(exp_shortest(strip_neg_zero(F), 0));
                %% fractionDigits specified → exactly `Fd` fraction digits with
                %% round-half-away-from-zero (ES2023 21.1.3.2: on an exact tie choose
                %% the larger mantissa). Erlang's {scientific,_} would round half-even,
                %% so this is rendered from the exact decimal expansion instead.
                _ ->
                    exp_specified(F, to_frac_digits(D))
            end
    end.

%% ToIntegerOrInfinity of a specified fractionDigits argument, clamped to a
%% non-negative digit count. Per ES ToIntegerOrInfinity, NaN (and any value that
%% coerces to NaN) maps to 0. The ±Infinity case (spec: RangeError) is not modelled
%% — exceptions are not yet supported — and is treated as 0 rather than crashing.
to_frac_digits(D) ->
    case coerce_num(D) of
        nan -> 0;
        inf -> 0;
        neg_inf -> 0;
        Dn -> max(0, trunc(as_float(Dn)))
    end.

%% Render `F` in exponential notation with exactly `Fd` fraction digits
%% (i.e. `Fd + 1` significant digits), rounding half-away-from-zero. Zero (and
%% negative zero, which the spec treats as non-negative) renders as "0[.0…]e+0".
exp_specified(F, Fd) when F == 0 ->
    Frac =
        case Fd of
            0 -> "";
            _ -> [$. | lists:duplicate(Fd, $0)]
        end,
    iolist_to_binary(["0", Frac, "e+0"]);
exp_specified(F, Fd) ->
    {Ds, E0} = float_sig_digits(abs(F)),
    {RD, Einc} = round_half_up_digits(Ds, Fd + 1),
    sci_from_digits(F < 0, RD, E0 + Einc, Fd + 1).

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
            %% precision undefined → ToString(thisNumberValue). Unwrap the receiver
            %% first so `Number.prototype.toPrecision()` (this value +0) yields "0"
            %% and `(new Number(7)).toPrecision(undefined)` yields "7".
            to_string(this_number_value(N));
        Pn ->
            case coerce_num(this_number_value(N)) of
                nan -> <<"NaN">>;
                inf -> <<"Infinity">>;
                neg_inf -> <<"-Infinity">>;
                Num -> precision_go(as_float(Num), max(1, trunc(as_float(Pn))))
            end
    end.

precision_go(F, P) when F == 0 ->
    num_to_fixed(0.0, P - 1);
precision_go(F, P) ->
    %% Round to `P` significant digits from the exact decimal expansion, using
    %% round-half-away-from-zero (ES2023 21.1.3.5). `E` is the decimal exponent of
    %% the leading digit AFTER rounding (a 9…9 → 10…0 carry bumps it). Per the spec
    %% the exponential form is used when E < -6 or E >= P, otherwise fixed.
    {Ds, E0} = float_sig_digits(abs(F)),
    {RD, Einc} = round_half_up_digits(Ds, P),
    E = E0 + Einc,
    case E < -6 orelse E >= P of
        true -> sci_from_digits(F < 0, RD, E, P);
        false -> num_to_fixed(F, P - 1 - E)
    end.

%% Exact significant decimal digits of a positive finite float `X`.
%%
%% Returns `{Ds, E}` where `Ds` is the non-empty digit string of the exact value
%% of `X` (an IEEE-754 double is a dyadic rational, so its decimal expansion is
%% finite and exact — no rounding here), with no leading zeros, and `E` is the
%% base-10 exponent of the leading digit, i.e. `X = Ds[0].Ds[1..] × 10^E`. Callers
%% round `Ds` to the desired number of significant digits themselves.
float_sig_digits(X) ->
    <<_S:1, Eb:11, M:52>> = <<X/float>>,
    {Mant, Exp} =
        case Eb of
            0 -> {M, -1074};
            _ -> {M + (1 bsl 52), Eb - 1075}
        end,
    case Exp >= 0 of
        true ->
            Ds = integer_to_list(Mant bsl Exp),
            {Ds, length(Ds) - 1};
        false ->
            %% X = Mant × 2^Exp = (Mant × 5^-Exp) × 10^Exp, and Mant × 5^-Exp is an
            %% integer whose digits are exactly the significant digits of X.
            Ds = integer_to_list(Mant * ipow5(-Exp)),
            {Ds, length(Ds) - 1 + Exp}
    end.

%% Exact 5^N for N >= 0 (bignum; used to convert a double's binary mantissa to its
%% exact decimal digits).
ipow5(N) -> ipow5(N, 1).
ipow5(0, Acc) -> Acc;
ipow5(N, Acc) -> ipow5(N - 1, Acc * 5).

%% Round the digit string `Ds` to `K` significant digits, half-away-from-zero.
%%
%% Returns `{RD, Einc}` where `RD` is exactly `K` digits and `Einc` is 1 when a
%% 9…9 → 10…0 carry increased the leading digit's power of ten (else 0). For a
%% positive digit string, rounding half-up means rounding up iff the first
%% discarded digit is >= 5 (an exact tie, discarded == 5000…, also rounds up).
round_half_up_digits(Ds, K) ->
    L = length(Ds),
    case L =< K of
        true ->
            {Ds ++ lists:duplicate(K - L, $0), 0};
        false ->
            {Head, [D | _]} = lists:split(K, Ds),
            case D >= $5 of
                false ->
                    {Head, 0};
                true ->
                    S = integer_to_list(list_to_integer(Head) + 1),
                    case length(S) > K of
                        true -> {lists:sublist(S, K), 1};
                        false -> {S, 0}
                    end
            end
    end.

%% Assemble an exponential-notation string from `K` rounded significant digits
%% `RD`, the leading digit's decimal exponent `E`, and a negative-sign flag.
%% Format matches JS: one integer digit, an optional fraction, then "e", a
%% mandatory sign, and the minimal-width exponent (e.g. "1.235e+4", "9e-1").
sci_from_digits(Neg, RD, E, K) ->
    Mant =
        case K of
            1 -> RD;
            _ -> [hd(RD), $. | tl(RD)]
        end,
    ESign =
        case E < 0 of
            true -> $-;
            false -> $+
        end,
    Sign =
        case Neg of
            true -> "-";
            false -> ""
        end,
    iolist_to_binary([Sign, Mant, $e, ESign, integer_to_list(abs(E))]).

%% num.toFixed(d) — fixed-point string with `d` decimals. Per the spec the sign is
%% "-" only when `x < 0`; negative zero is not `< 0` and renders as "0…", so ±0 is
%% normalised before formatting. A genuinely-negative value that merely ROUNDS to
%% zero (e.g. `(-0.0001).toFixed(2)` → "-0.00") is untouched — only exact ±0 changes.
num_to_fixed(N, D) ->
    Digits =
        case coerce_num(D) of
            nan -> 0;
            _ -> max(0, trunc(as_float(coerce_num(D))))
        end,
    case coerce_num(this_number_value(N)) of
        nan -> <<"NaN">>;
        inf -> <<"Infinity">>;
        neg_inf -> <<"-Infinity">>;
        Num -> float_to_binary(strip_neg_zero(as_float(Num)), [{decimals, Digits}])
    end.

%% thisNumberValue(this value) for the Number.prototype formatting methods
%% (§21.1.3): a `new Number(x)` wrapper object unwraps to its boxed primitive
%% number; the %NumberPrototype% object itself has a [[NumberData]] internal slot
%% with value +0 (ES §21.1.4), so a method invoked as `Number.prototype.toFixed(…)`
%% must see +0; every other value (a primitive number, or anything else) passes
%% through unchanged so the caller's `coerce_num` handles it. Per spec a non-Number
%% receiver is a TypeError, but exceptions on the receiver are not modelled here —
%% a non-wrapper simply falls through to the ordinary numeric coercion.
this_number_value(N) ->
    case cell_tag(N) of
        {js_wrapper, number, Prim} ->
            Prim;
        _ ->
            case is_reference(N) andalso N =:= builtin_prototype(<<"Number">>) of
                true -> 0.0;
                false -> N
            end
    end.

%% Normalise negative zero to positive zero (any non-zero float is returned
%% unchanged). Used by the Number formatting methods, whose spec algorithms treat
%% `x = -0` as non-negative and therefore emit no leading "-".
strip_neg_zero(F) when F == 0 -> 0.0;
strip_neg_zero(F) -> F.

%% ── array value methods ──────────────────────────────────

%% indexOf(searchElement, fromIndex) — first === index at or after `fromIndex`
%% (ToIntegerOrInfinity, negatives from the end, clamped), else -1. A string
%% receiver does a substring search honouring the `position` argument.
array_index_of(Recv, X, From) when is_binary(Recv) -> str_index_of(Recv, X, From);
array_index_of(Recv, X, From) ->
    {Len, _Map} = arr_content(Recv),
    Start = idx_from(From, Len),
    aidx(Recv, Start, Len, X).

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

%% Per ES §22.1.3.14, indexOf visits only indices the array HAS (holes are
%% skipped via HasProperty, so `[0, , 2].indexOf(undefined)` is -1) and re-reads
%% the live array each step. `Len` bounds iteration from `K` upward.
aidx(_Arr, K, Len, _X) when K >= Len -> -1;
aidx(Arr, K, Len, X) ->
    case arr_index(Arr, K) of
        {ok, E} ->
            case strict_eq(E, X) of
                1 -> K;
                0 -> aidx(Arr, K + 1, Len, X)
            end;
        error ->
            aidx(Arr, K + 1, Len, X)
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

%% join(separator?) — ToString each element (holes / null / undefined render as
%% the empty string) and interleave `separator`. Per ES §23.1.3.18 step 3, an
%% `undefined` separator is NOT ToString'd to "undefined"; it defaults to the
%% single comma ",", so `[1, 2].join(undefined)` is "1,2". Any other separator
%% (including `null`) is ToString'd normally.
array_join(Recv, Sep) ->
    {Len, Map} = arr_content(Recv),
    SepBin =
        case Sep of
            undefined -> <<",">>;
            _ -> to_string(Sep)
        end,
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
    case char_at_index(Pos, cps(str_this(Str))) of
        {ok, C} -> from_cps([C]);
        error -> <<>>
    end.

%% str.charCodeAt(pos) → the code point at index `pos` as a number, or NaN when
%% out of range. `pos` is ToIntegerOrInfinity, exactly as in str_char_at.
str_char_code_at(Str, Pos) ->
    case char_at_index(Pos, cps(str_this(Str))) of
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
    Cps = cps(str_this(Str)),
    case Idx >= 0 andalso Idx < length(Cps) of
        true -> lists:nth(Idx + 1, Cps);
        false -> undefined
    end.

str_upper(Str) -> unicode:characters_to_binary(string:uppercase(str_this(Str))).
str_lower(Str) -> unicode:characters_to_binary(string:lowercase(str_this(Str))).

%% str.isWellFormed() — §22.1.3.9. Returns the JS boolean `true` when the string
%% contains no unpaired UTF-16 surrogate, else `false`. Implemented at the code-point
%% level: a code point in the surrogate range 0xD800..0xDFFF can only appear when it
%% was an unpaired surrogate in the source (a valid pair is decoded to its astral code
%% point). Note the v1 code-point deviation: this engine replaces lone surrogates with
%% U+FFFD when a string is created, so in practice every stored string is well-formed
%% and this predicate returns `true` — the surrogate scan is kept for correctness.
str_is_well_formed(Str) ->
    case has_lone_surrogate(cps(Str)) of
        true -> false;
        false -> true
    end.

has_lone_surrogate([C | _Rest]) when C >= 16#D800, C =< 16#DFFF -> true;
has_lone_surrogate([_ | Rest]) -> has_lone_surrogate(Rest);
has_lone_surrogate([]) -> false.

%% str.toWellFormed() — §22.1.3.35. Returns a copy of the string with every unpaired
%% surrogate code point replaced by U+FFFD (REPLACEMENT CHARACTER). Per the v1
%% code-point deviation lone surrogates are already replaced with U+FFFD at string
%% creation, so this is effectively the identity; the explicit replacement keeps the
%% algorithm correct for any code point that reaches it in the surrogate range.
str_to_well_formed(Str) ->
    from_cps([replace_surrogate(C) || C <- cps(Str)]).

replace_surrogate(C) when C >= 16#D800, C =< 16#DFFF -> 16#FFFD;
replace_surrogate(C) -> C.

%% str.localeCompare(that) — §22.1.3.10 / sec-string.prototype.localecompare. With no
%% locale/collator support this uses the default (code-unit, i.e. code-point for the
%% BMP) lexicographic ordering: returns the JS number -1 when `Str` sorts before
%% `That`, 1 when after, and 0 when they are equal. `That` is coerced with ToString.
str_locale_compare(Str, That) ->
    ThatStr = to_string(That),
    A = cps(Str),
    B = cps(ThatStr),
    if
        A < B -> -1;
        A > B -> 1;
        true -> 0
    end.

%% `String.prototype.<method>` referenced as a VALUE (e.g. `typeof
%% String.prototype.at`, or passing the method around). Returns the underlying
%% builtin as a bare BEAM closure so `typeof` reports "function" and a direct
%% application `String.prototype.at(str, i)` reaches the implementation. NOTE: like
%% every function in this model the closure carries no bound receiver, so
%% `String.prototype.at.call(thisArg, …)` forwards only the trailing arguments (the
%% `thisArg` is dropped by Function.prototype.call) — a documented v1 limitation.
%% Only the fixed set of string methods routed here (see `lower`) is exposed.
str_proto_fn(<<"at">>) -> fun array_at/2;
str_proto_fn(<<"charAt">>) -> fun str_char_at/2;
str_proto_fn(<<"charCodeAt">>) -> fun str_char_code_at/2;
str_proto_fn(<<"codePointAt">>) -> fun str_code_point_at/2;
str_proto_fn(<<"toUpperCase">>) -> fun str_upper/1;
str_proto_fn(<<"toLowerCase">>) -> fun str_lower/1;
str_proto_fn(<<"trim">>) -> fun str_trim/1;
str_proto_fn(<<"trimStart">>) -> fun str_trim_start/1;
str_proto_fn(<<"trimEnd">>) -> fun str_trim_end/1;
str_proto_fn(<<"isWellFormed">>) -> fun str_is_well_formed/1;
str_proto_fn(<<"toWellFormed">>) -> fun str_to_well_formed/1;
str_proto_fn(<<"localeCompare">>) -> fun str_locale_compare/2.

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
    Cps = cps(str_this(Str)),
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
%% str.split(separator, limit) — §22.1.3.21. `limit` bounds the number of
%% substrings in the result: it is coerced with ToUint32, and when the limit is
%% 0 the result is an empty array regardless of the separator (spec step 8: "If
%% lim = 0, return A"). An `undefined` limit means 2^32-1 (effectively
%% unbounded). A larger limit truncates the raw split to that many leading
%% substrings.
str_split(Str0, Sep, Limit) ->
    Str = str_this(Str0),
    case split_limit(Limit) of
        0 -> new_array([]);
        Lim -> new_array(split_take(str_split_all(Str, Sep), Lim))
    end.

%% Coerce a String-method `this` receiver to its primitive string binary, per the
%% String.prototype algorithm `S = ToString(RequireObjectCoercible(this))` (e.g.
%% §22.1.3.21 split step 2, §22.1.3.30 trim). RequireObjectCoercible: `undefined`/
%% `null` throw a TypeError (so `String.prototype.trim.call(undefined)` throws, as the
%% spec requires). A plain string passes through unchanged; everything else — a
%% `new String(x)` (and other primitive) WRAPPER cell, an array, a plain object, or a
%% bare number/boolean primitive — is `to_string`-coerced (which unwraps a wrapper to
%% its boxed primitive, joins an array, and renders a plain object as "[object
%% Object]"). This is what makes `String.prototype.trim.call(0)` yield "0",
%% `.call(false)` yield "false", and `.call([1])` yield "1" once a generic `.call`
%% forwards the receiver here.
%% A Symbol receiver is a TypeError: ToString of a Symbol is abrupt (§7.1.17,
%% ToString step 2), so `String.prototype.substring.call(Symbol())` throws.
str_this(undefined) -> type_error(undefined);
str_this(null) -> type_error(null);
str_this(V) when is_binary(V) -> V;
str_this({js_symbol, _, _}) ->
    type_error(<<"Cannot convert a Symbol value to a string">>);
str_this(V) -> to_string(V).

%% ToUint32(limit) with `undefined` mapped to the spec's 2^32-1 default. NaN and
%% ±Infinity coerce to 0; any other number is truncated toward zero and reduced
%% modulo 2^32.
split_limit(undefined) -> 16#FFFFFFFF;
split_limit(Limit) ->
    case coerce_num(Limit) of
        nan -> 0;
        inf -> 0;
        neg_inf -> 0;
        Num -> trunc(as_float(Num)) band 16#FFFFFFFF
    end.

%% Keep at most `Lim` leading elements of the raw split list.
split_take(List, Lim) when Lim >= length(List) -> List;
split_take(List, Lim) -> lists:sublist(List, Lim).

%% The full (unlimited) split of `Str` by `Sep`, as an Erlang list of the
%% substrings a limit would then bound. Mirrors the previous unlimited split:
%% `undefined`/non-regex-reference separators yield the whole string; an empty
%% string separator splits into individual code points; a regex delegates to
%% `str_split_regex`; any other value is coerced with ToString.
str_split_all(Str, undefined) ->
    [Str];
str_split_all(Str, Sep) when is_reference(Sep) ->
    case is_regex(Sep) of
        true -> array_to_list(str_split_regex(Str, Sep));
        false -> [Str]
    end;
str_split_all(Str, Sep) ->
    case to_string(Sep) of
        <<>> -> [from_cps([C]) || C <- cps(Str)];
        SepBin -> binary:split(Str, SepBin, [global])
    end.

%% str.trim() / trimStart() / trimEnd() — remove leading and/or trailing runs
%% of code points that are JS WhiteSpace or LineTerminator (see `is_js_ws/1`).
%% The JS whitespace set differs from Erlang's `string:trim` default (it must
%% include U+FEFF and U+00A0 and excludes non-WhiteSpace Unicode spaces), so we
%% trim against the ECMAScript set explicitly.
str_trim(Str) -> from_cps(trim_trailing(trim_leading(cps(str_this(Str))))).
str_trim_start(Str) -> from_cps(trim_leading(cps(str_this(Str)))).
str_trim_end(Str) -> from_cps(trim_trailing(cps(str_this(Str)))).

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
    S = str_this(Str),
    P = to_string(Prefix),
    Cps = cps(S),
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
    Recv = str_this(Str),
    S = to_string(Suffix),
    Cps = cps(Recv),
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
    case is_regex(Search) of
        true ->
            %% replaceAll with a NON-global regex is a TypeError (§22.1.3.20);
            %% a global one replaces every match via the regex replace path.
            {_MP, Flags, _S} = regex_content(Search),
            case has_flag(Flags, $g) of
                true -> str_replace_regex(Str, Search, Repl);
                false -> type_error(Search)
            end;
        false ->
            ReplBin = to_string(Repl),
            case to_string(Search) of
                <<>> -> ra_empty(cps(Str), ReplBin, <<>>);
                SearchBin -> ra_expand(Str, SearchBin, ReplBin, Str, 0, <<>>)
            end
    end.

%% replaceAll with an EMPTY search string. Per §22.1.3.20 the empty string is
%% found (via StringIndexOf) at every position 0..len, so the replacement is
%% inserted before each code point AND once at the very end — e.g.
%% `'a'.replaceAll('', '_')` → `'_a_'` and `''.replaceAll('', 'abc')` → `'abc'`.
%% At each empty match the matched text is empty, with `Before` = the code
%% points already consumed and `After` = the remaining code points, so the
%% `` $` `` / `$'` substitutions expand against the correct sides of the split.
ra_empty([], Repl, Before) ->
    expand_repl(Repl, <<>>, Before, <<>>);
ra_empty([C | Rest], Repl, Before) ->
    After = from_cps([C | Rest]),
    Expanded = expand_repl(Repl, <<>>, Before, After),
    Ch = from_cps([C]),
    Tail = ra_empty(Rest, Repl, <<Before/binary, Ch/binary>>),
    <<Expanded/binary, Ch/binary, Tail/binary>>.

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

%% ───────────────────────── escape / unescape (Annex B) ─────────────────────
%%
%% The legacy Annex B string escapers (B.2.1). Unlike the URI functions these
%% operate on UTF-16 CODE UNITS, not bytes: a code unit ≥ 256 becomes `%uWXYZ`
%% (four uppercase hex), a code unit < 256 that is not in the unescaped set
%% becomes `%XY` (two uppercase hex), and the unescaped set stays literal. JS
%% strings are UTF-8 binaries here, so escape first decodes to code points and
%% re-expands any astral code point (> U+FFFF) into its UTF-16 surrogate pair,
%% matching e.g. escape('\u{10401}') === '%uD801%uDC01'.

%% escape(string) — B.2.1.1. Percent-escapes ToString(string) code-unit by
%% code-unit, leaving only the unescaped set literal. Never raises.
global_escape(V) ->
    CUs = string_to_code_units(to_string(V)),
    list_to_binary(lists:map(fun esc_unit/1, CUs)).

%% One escaped code unit (0..16#FFFF) as an iolist fragment.
esc_unit(U) when U < 256 ->
    case esc_unescaped(U) of
        true -> <<U>>;
        false -> <<$%, (uri_hex2(U))/binary>>
    end;
esc_unit(U) ->
    <<$%, $u, (esc_hex4(U))/binary>>.

%% escape's unescaped set: uriAlpha | DecimalDigit | "@*_+-./".
esc_unescaped(B) ->
    (B >= $A andalso B =< $Z) orelse
        (B >= $a andalso B =< $z) orelse
        (B >= $0 andalso B =< $9) orelse
        lists:member(B, [$@, $*, $_, $+, $-, $., $/]).

%% The four UPPERCASE hex digits of a code unit (0..16#FFFF), as a 4-byte binary.
esc_hex4(U) ->
    <<(uri_hexdig((U bsr 12) band 16#F)), (uri_hexdig((U bsr 8) band 16#F)),
        (uri_hexdig((U bsr 4) band 16#F)), (uri_hexdig(U band 16#F))>>.

%% Decode a UTF-8 string binary into the list of its UTF-16 code units: each
%% code point ≤ U+FFFF is one unit; an astral code point becomes a high/low
%% surrogate pair.
string_to_code_units(Bin) ->
    lists:flatmap(fun code_point_to_units/1, unicode:characters_to_list(Bin, utf8)).

code_point_to_units(CP) when CP > 16#FFFF ->
    C = CP - 16#10000,
    [16#D800 bor (C bsr 10), 16#DC00 bor (C band 16#3FF)];
code_point_to_units(CP) ->
    [CP].

%% unescape(string) — B.2.1.2. Reverses escape: `%uXXXX` → that code unit,
%% `%XX` → that code unit, everything else passes through. A `%` not followed by
%% a well-formed escape is left verbatim (case preserved). Never raises.
global_unescape(V) -> unesc(to_string(V), <<>>).

unesc(<<$%, $u, A, B, C, D, Rest/binary>>, Acc) ->
    case
        {uri_hexval(A), uri_hexval(B), uri_hexval(C), uri_hexval(D)}
    of
        {D1, D2, D3, D4} when
            is_integer(D1), is_integer(D2), is_integer(D3), is_integer(D4)
        ->
            CU = ((D1 * 16 + D2) * 16 + D3) * 16 + D4,
            unesc(Rest, <<Acc/binary, CU/utf8>>);
        _ ->
            unesc(<<$u, A, B, C, D, Rest/binary>>, <<Acc/binary, $%>>)
    end;
unesc(<<$%, A, B, Rest/binary>>, Acc) ->
    case {uri_hexval(A), uri_hexval(B)} of
        {D1, D2} when is_integer(D1), is_integer(D2) ->
            CU = D1 * 16 + D2,
            unesc(Rest, <<Acc/binary, CU/utf8>>);
        _ ->
            unesc(<<A, B, Rest/binary>>, <<Acc/binary, $%>>)
    end;
unesc(<<C, Rest/binary>>, Acc) ->
    unesc(Rest, <<Acc/binary, C>>);
unesc(<<>>, Acc) ->
    Acc.

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
obj_pairs(O) when is_binary(O) ->
    %% ToObject(string): a String exotic object whose own enumerable properties
    %% are the indexed characters "0".."len-1" (each a one-char string), in
    %% ascending index order (ES2015+ Object.keys/values/entries coerce, not throw).
    Cps = cps(O),
    [
        {integer_to_binary(I), from_cps([lists:nth(I + 1, Cps)])}
     || I <- lists:seq(0, length(Cps) - 1)
    ];
obj_pairs(O) ->
    %% ToObject(v): numbers, booleans and functions wrap to objects with NO own
    %% enumerable string keys; null/undefined (and internal reprs) are not
    %% coercible and raise a TypeError.
    case js_type(O) of
        number -> [];
        boolean -> [];
        function -> [];
        _ -> type_error(O)
    end.

%% is `x` null or undefined? → i32 1|0 (behind `??` and `?.`).
is_nullish(null) -> 1;
is_nullish(undefined) -> 1;
is_nullish(_) -> 0.

%% keys are listed WITHOUT invoking getters; values/entries resolve accessors.
object_keys(O) -> new_array([K || {K, _} <- obj_pairs(O)]).

%% Object.values / Object.entries follow EnumerableOwnPropertyNames (ES2020 7.3.23):
%% the own enumerable key *names* are snapshotted up front, then each key is
%% visited in order and, for every key, its presence is re-checked and its value
%% re-read via [[Get]] AT VISIT TIME. A getter that runs while an earlier key is
%% being read can delete a later key; that later key must then be skipped rather
%% than reported with a stale snapshot value. `object_visit_own_keys/1` performs
%% that re-checking pass and returns `[{Key, Value}]` for the keys still present.
object_values(O) ->
    new_array([V || {_, V} <- object_visit_own_keys(O)]).
object_entries(O) ->
    new_array([new_array([K, V]) || {K, V} <- object_visit_own_keys(O)]).

%% Snapshot the own enumerable key names of `O`, then re-visit them in order,
%% dropping any key no longer present (deleted by an earlier key's getter) and
%% reading the surviving keys' current values with [[Get]] (invoking accessors,
%% `this`-bound to `O`). Returns `[{Key, Value}]` in the original key order.
object_visit_own_keys(O) ->
    Keys = [K || {K, _} <- obj_pairs(O)],
    lists:filtermap(
        fun(K) ->
            case object_has_own(O, K) of
                true -> {true, {K, get_prop(O, K)}};
                false -> false
            end
        end,
        Keys
    ).

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

%% Copy `source`'s own enumerable properties into `target` (in place); behind
%% object spread `{...o}` and `Object.assign`. Per spec each source is ToObject-
%% coerced: `null`/`undefined` are skipped (no-op), a string spreads its indexed
%% characters ("0".."n-1"), and numbers/booleans/functions contribute no keys.
object_assign_into(Target, null) ->
    Target;
object_assign_into(Target, undefined) ->
    Target;
object_assign_into(Target, Source) ->
    lists:foreach(
        fun({K, V}) -> set_prop(Target, K, resolve_get(V)) end, obj_pairs(Source)
    ),
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
%% String/Number/Boolean wrapper objects ARE unwrapped to their primitive per
%% SerializeJSONProperty step 4 (see `json_unwrap_primitive`). A cyclical
%% structure raises a TypeError (see `json_serialize_cell`). Deviation:
%% `this`-bound `toJSON`/replacer receivers are still not modelled.
json_stringify(V, Replacer, Space) ->
    erlang:erase(json_stack),
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
%% Per sec-json.stringify step 5, a `space` that is a Number wrapper object
%% (`new Number(n)`) is first coerced to its boxed number, and a String wrapper
%% (`new String(s)`) to its boxed string, before the Number/String cases apply.
json_gap(N) when is_integer(N) -> json_gap_spaces(N);
json_gap(N) when is_float(N) -> json_gap_spaces(trunc(N));
json_gap(js_inf) -> binary:copy(<<" ">>, 10);
json_gap(js_neg_inf) -> <<>>;
json_gap(js_nan) -> <<>>;
json_gap(S) when is_binary(S) -> from_cps(lists:sublist(cps(S), 10));
json_gap(Ref) when is_reference(Ref) ->
    case erlang:get(?CELL_KEY(Ref)) of
        {js_wrapper, number, Prim} -> json_gap(Prim);
        {js_wrapper, string, Prim} -> json_gap(Prim);
        _ -> <<>>
    end;
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
%% This applies to plain objects AND to arrays: an array is an object, so a
%% `toJSON` method assigned to it (`arr.toJSON = ...`) must be honoured — e.g. a
%% `toJSON` returning `undefined` makes `JSON.stringify(arr)` yield `undefined`
%% rather than serializing the array's elements.
json_apply_tojson(Key, V) when is_reference(V) ->
    case erlang:get(?CELL_KEY(V)) of
        M when is_map(M) ->
            json_call_tojson(Key, V, maps:get(<<"toJSON">>, M, undefined));
        {js_array, _Len, Map} ->
            json_call_tojson(Key, V, maps:get(<<"toJSON">>, Map, undefined));
        _ ->
            V
    end;
json_apply_tojson(_Key, V) ->
    V.

%% If `Stored` (the raw `toJSON` slot, possibly an accessor) resolves to a
%% callable, return `toJSON(key)`; otherwise return the untouched value `V`.
json_call_tojson(Key, V, Stored) ->
    case resolve_get(Stored) of
        Fn when is_function(Fn) -> call_cb(Fn, [Key]);
        _ -> V
    end.

json_serialize_value(V, St, Indent) ->
    case json_unwrap_primitive(V) of
        {primitive, Prim} ->
            json_serialize_value(Prim, St, Indent);
        no ->
            case js_type(V) of
                number -> json_num(V);
                boolean -> to_string(V);
                string -> json_str(V);
                null -> <<"null">>;
                undefined -> skip;
                function -> skip;
                object -> json_serialize_cell(V, St, Indent);
                other -> skip
            end
    end.

%% SerializeJSONProperty steps 4.a–4.c: a Number/String/Boolean wrapper OBJECT
%% (`new Number(n)` / `new String(s)` / `new Boolean(b)`) is serialized as its
%% wrapped primitive [[NumberData]]/[[StringData]]/[[BooleanData]], NOT as an
%% object — so `JSON.stringify(new Boolean(true))` yields `"true"`, not `"{}"`,
%% and a wrapper nested inside an object/array or returned from a replacer/toJSON
%% is serialized by its primitive too. Returns `{primitive, Prim}` for a wrapper
%% cell, `no` for any other value.
json_unwrap_primitive(V) when is_reference(V) ->
    case erlang:get(?CELL_KEY(V)) of
        {js_wrapper, _Kind, Prim} -> {primitive, Prim};
        _ -> no
    end;
json_unwrap_primitive(_) ->
    no.

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
%%
%% SerializeJSONObject/SerializeJSONArray step 1: "If stack contains value, throw
%% a TypeError exception because the structure is cyclical." The stack is the set
%% of object/array cells currently being serialized (an ancestor chain), tracked
%% in the process dictionary under `json_stack`. A cell is pushed on entry and
%% popped on exit (via `after`, so it is restored on a thrown TypeError too), so a
%% value that merely appears twice in DIFFERENT branches (a diamond, not a cycle)
%% is NOT rejected. A truly cyclical reference recurses back to an ancestor still
%% on the stack and raises `type_error`, which a JS `try`/`catch` observes as a
%% TypeError — without this, a self-referential object looped forever.
json_serialize_cell(Ref, St, Indent) ->
    Stack =
        case erlang:get(json_stack) of
            undefined -> [];
            L -> L
        end,
    case lists:member(Ref, Stack) of
        true ->
            type_error(Ref);
        false ->
            erlang:put(json_stack, [Ref | Stack]),
            try
                case erlang:get(?CELL_KEY(Ref)) of
                    {js_array, Len, _Map} ->
                        json_serialize_array(Ref, Len, St, Indent);
                    M when is_map(M) ->
                        json_serialize_object(Ref, M, St, Indent);
                    _ ->
                        <<"{}">>
                end
            after
                erlang:put(json_stack, Stack)
            end
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
    case json_num_raw(Tok) of
        error -> error;
        V -> json_neg_zero_fixup(Tok, V)
    end.

json_num_raw(Tok) ->
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

%% A JSON number whose mathematical value is zero but which carries a leading
%% minus sign (e.g. "-0", "-0.0", "-0e10") has the math value negative zero, and
%% ECMAScript's JSON.parse preserves it as the IEEE-754 value -0 (sec-json.parse
%% parses per ECMA-404, then the MV feeds ToNumber which distinguishes ±0).
%% binary_to_integer("-0") returns positive integer 0, so re-tag any zero-valued
%% leading-minus token as the float -0.0.
json_neg_zero_fixup(<<$-, _/binary>>, V) when V == 0 -> -0.0;
json_neg_zero_fixup(_, V) -> V.

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
