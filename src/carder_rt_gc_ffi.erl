%%% carder_rt_gc_ffi — the WebAssembly GC arena (this proposal).
%%%
%%% Hand-written Erlang (so it carries the `carder_` namespace prefix and can
%%% never collide with an OTP module). It is the single owner of the GC heap
%%% representation, imported only through `rt_gc` (the Gleam seam `emit_core`
%%% calls). Plain core-WASM modules never reach it — the whole-program linker
%%% drops `rt_gc` (and this shim) unless a GC instruction is emitted.
%%%
%%% ## Why a per-process arena
%%%
%%% WasmGC objects are MUTABLE and have REFERENCE IDENTITY (two `struct.new`s are
%%% distinct even with equal fields; `struct.set` mutates in place, visible through
%%% every alias). BEAM terms are immutable, so a reference is a HANDLE `{gc, Id}`
%%% into the process dictionary, which is the mutable store: the object for `Id`
%%% lives under `{gc_obj, Id}` and `struct.set`/`array.set` overwrite it. A module
%%% instance runs in one process, so the arena is process-local; it is reclaimed
%%% automatically when that process dies (no manual free, no cross-process refs).
%%%
%%% ## Value representation
%%%
%%%   null        -> {ref_null}          (shared with rt_ref — one null for all)
%%%   struct/array-> {gc, Id}            (Id a per-process monotonic integer)
%%%   i31         -> {i31, V}            (V the low 31 bits, in [0, 2^31))
%%%   heap object -> {struct, TypeIdx, FieldsTuple} | {array, TypeIdx, ElemsTuple}
%%%
%%% Numbers follow carder's convention: an i32 is its UNSIGNED bit pattern in
%%% [0, 2^32). Plain fields store/return the term verbatim; packed i8/i16 fields
%%% are masked (and, for the signed read, sign-extended) on read — `unpack/3`.
%%%
%%% ## Traps
%%%
%%% Raised exactly like `rt_trap`: `erlang:error({wasm_trap, Kind})` at error
%%% class, so the conformance harness's `catch error:{wasm_trap, Kind}` sees them.
%%% Kinds: `null_reference` (access through null), `cast_failure` (`ref.cast`
%%% miss), `array_out_of_bounds` (`array.*` index/range).
-module(carder_rt_gc_ffi).

-export([
    struct_new/2, struct_get/2, struct_get_packed/4, struct_set/3,
    array_new/3, array_new_fixed/2, array_get/2, array_get_packed/4,
    array_set/3, array_len/1, array_fill/4, array_copy/5,
    ref_i31/1, i31_get_s/1, i31_get_u/1,
    ref_test/3, ref_cast/3, ref_eq/2, ref_as_non_null/1,
    any_convert_extern/1, extern_convert_any/1,
    call_ref/3, t_call_ref/4, apply_ref/2, t_apply_ref/3,
    array_new_data/5, array_init_data/6, array_new_elem/4, array_init_elem/5
]).

%% ─────────────────────────────── allocation ───────────────────────────────

%% A fresh monotonic object id for this process.
alloc() ->
    Id = case get('$gc_next') of
             undefined -> 0;
             N -> N
         end,
    put('$gc_next', Id + 1),
    Id.

%% ──────────────────────────────── structs ─────────────────────────────────

%% struct.new $t : allocate a struct with the given (bottom-first) field values.
struct_new(TypeIdx, Fields) ->
    Id = alloc(),
    put({gc_obj, Id}, {struct, TypeIdx, list_to_tuple(Fields)}),
    {gc, Id}.

%% struct.get $t $f (plain, non-packed field).
struct_get({ref_null}, _Field) -> null_struct_trap();
struct_get({gc, Id}, Field) ->
    {struct, _T, Fs} = get({gc_obj, Id}),
    element(Field + 1, Fs).

%% struct.get_s / struct.get_u $t $f (packed field → i32).
struct_get_packed({ref_null}, _F, _B, _S) -> null_struct_trap();
struct_get_packed({gc, Id}, Field, Bits, Signed) ->
    {struct, _T, Fs} = get({gc_obj, Id}),
    unpack(element(Field + 1, Fs), Bits, Signed).

%% struct.set $t $f.
struct_set({ref_null}, _F, _V) -> null_struct_trap();
struct_set({gc, Id}, Field, Val) ->
    {struct, T, Fs} = get({gc_obj, Id}),
    put({gc_obj, Id}, {struct, T, setelement(Field + 1, Fs, Val)}),
    ok.

%% ───────────────────────────────── arrays ─────────────────────────────────

%% array.new $t : `Count` copies of `Elem`.
array_new(TypeIdx, Elem, Count) ->
    Id = alloc(),
    put({gc_obj, Id}, {array, TypeIdx, erlang:make_tuple(Count, Elem)}),
    {gc, Id}.

%% array.new_fixed $t N : the given (bottom-first) elements.
array_new_fixed(TypeIdx, Elems) ->
    Id = alloc(),
    put({gc_obj, Id}, {array, TypeIdx, list_to_tuple(Elems)}),
    {gc, Id}.

array_get({ref_null}, _Idx) -> null_array_trap();
array_get({gc, Id}, Idx) ->
    {array, _T, Es} = get({gc_obj, Id}),
    check_bounds(Idx, tuple_size(Es)),
    element(Idx + 1, Es).

array_get_packed({ref_null}, _I, _B, _S) -> null_array_trap();
array_get_packed({gc, Id}, Idx, Bits, Signed) ->
    {array, _T, Es} = get({gc_obj, Id}),
    check_bounds(Idx, tuple_size(Es)),
    unpack(element(Idx + 1, Es), Bits, Signed).

array_set({ref_null}, _I, _V) -> null_array_trap();
array_set({gc, Id}, Idx, Val) ->
    {array, T, Es} = get({gc_obj, Id}),
    check_bounds(Idx, tuple_size(Es)),
    put({gc_obj, Id}, {array, T, setelement(Idx + 1, Es, Val)}),
    ok.

array_len({ref_null}) -> null_array_trap();
array_len({gc, Id}) ->
    {array, _T, Es} = get({gc_obj, Id}),
    tuple_size(Es).

array_fill({ref_null}, _I, _V, _C) -> null_array_trap();
array_fill({gc, Id}, Idx, Val, Count) ->
    {array, T, Es} = get({gc_obj, Id}),
    check_range(Idx, Count, tuple_size(Es)),
    put({gc_obj, Id}, {array, T, fill_slice(Es, Idx, Val, Count)}),
    ok.

%% array.copy dst-ref dst-idx src-ref src-idx count. The source slice is read into
%% a list first, so an overlapping same-array copy behaves as if via a temporary.
array_copy({ref_null}, _Di, _Src, _Si, _C) -> null_array_trap();
array_copy(_Dst, _Di, {ref_null}, _Si, _C) -> null_array_trap();
array_copy({gc, Did}, Di, {gc, Sid}, Si, Count) ->
    {array, DT, DEs} = get({gc_obj, Did}),
    {array, _ST, SEs} = get({gc_obj, Sid}),
    check_range(Di, Count, tuple_size(DEs)),
    check_range(Si, Count, tuple_size(SEs)),
    Slice = [element(Si + K + 1, SEs) || K <- seq0(Count)],
    put({gc_obj, Did}, {array, DT, write_slice(DEs, Di, Slice)}),
    ok.

%% ────────────────────────────────── i31 ───────────────────────────────────

%% ref.i31 : keep the low 31 bits.
ref_i31(N) -> {i31, N band 16#7FFFFFFF}.

%% i31.get_s : sign-extend from bit 30 to the 32-bit unsigned pattern.
i31_get_s({ref_null}) -> null_i31_trap();
i31_get_s({i31, V}) -> sign_extend(V, 31).

%% i31.get_u : the 31-bit value (already a valid non-negative i32).
i31_get_u({ref_null}) -> null_i31_trap();
i31_get_u({i31, V}) -> V.

%% ───────────────────────────── casts / equality ───────────────────────────

%% ref.test rt : 1 if the operand's runtime type matches `Matcher` (null iff
%% `NullOk`), else 0. `Matcher` is {concrete, [TypeIdx]} | {abstract, Kind}.
ref_test({ref_null}, _M, NullOk) -> bool_i32(NullOk =:= true);
ref_test(Ref, Matcher, _NullOk) -> bool_i32(matches(Ref, Matcher)).

%% ref.cast rt : the operand if it matches (null iff `NullOk`), else trap.
ref_cast({ref_null}, _M, NullOk) ->
    case NullOk =:= true of
        true -> {ref_null};
        false -> cast_trap()
    end;
ref_cast(Ref, Matcher, _NullOk) ->
    case matches(Ref, Matcher) of
        true -> Ref;
        false -> cast_trap()
    end.

%% ref.eq : reference identity. Every eq value ({gc,_}, {i31,_}, {ref_null}) is a
%% ground term, so structural `=:=` is exactly reference equality.
ref_eq(A, B) -> bool_i32(A =:= B).

%% ref.as_non_null : the operand, or trap on null.
ref_as_non_null({ref_null}) -> null_trap();
ref_as_non_null(Ref) -> Ref.

%% any.convert_extern / extern.convert_any : the external/internal boxing is
%% representation-identity here (the same term flows, nullability preserved).
any_convert_extern(Ref) -> Ref.
extern_convert_any(Ref) -> Ref.

%% ─────────────────────── typed function references ────────────────────────

%% call_ref $t : apply a funcref `#(FuncType, Closure)` to `Args`, returning the
%% callee's `ResultCount` results as a list (null → trap). `Cell`-build ABI: the
%% stored closure is `fun(Args) -> Package`. The closure is build-controlled (from
%% ref.func / an element segment), so this is a direct fun application, never an
%% `apply/3` of program data (D3a).
call_ref({ref_null}, _Args, _RC) ->
    erlang:error({wasm_trap, null_reference});
call_ref({_Type, Closure}, Args, RC) ->
    pkg_to_list(Closure(Args), RC).

%% call_ref $t, `Threaded`-build ABI: the closure is `fun(St, Args) -> {Package,
%% St'}`; thread the instance state through and return `{Results, St'}`.
t_call_ref(_St, {ref_null}, _Args, _RC) ->
    erlang:error({wasm_trap, null_reference});
t_call_ref(St, {_Type, Closure}, Args, RC) ->
    {Pkg, St2} = Closure(St, Args),
    {pkg_to_list(Pkg, RC), St2}.

%% return_call_ref $t : TAIL-apply a funcref to `Args`. The closure application is
%% in tail position of this function, and the generated caller tail-calls it, so a
%% tail-recursive chain runs in constant stack. Returns the callee's package
%% verbatim (the caller's tail-return shape). Null → trap. `Cell`-build ABI.
apply_ref({ref_null}, _Args) ->
    erlang:error({wasm_trap, null_reference});
apply_ref({_Type, Closure}, Args) ->
    Closure(Args).

%% return_call_ref $t, `Threaded`-build ABI: the closure is `fun(St, Args) ->
%% {Package, St'}`; tail-apply it, threading state. Returns `{Package, St'}`.
t_apply_ref(_St, {ref_null}, _Args) ->
    erlang:error({wasm_trap, null_reference});
t_apply_ref(St, {_Type, Closure}, Args) ->
    Closure(St, Args).

%% Convert a callee's package-ABI return into the ResultCount-length result list:
%% 'ok' → [], a bare value → [V], an N-tuple → its element list (mirrors
%% rt_table's package_to_list, the frozen call_indirect result contract).
pkg_to_list(_Pkg, 0) -> [];
pkg_to_list(Pkg, 1) -> [Pkg];
pkg_to_list(Pkg, _) -> tuple_to_list(Pkg).

%% ─────────────────────── segment-sourced array init ───────────────────────

%% array.new_data $t $d : a new array of `Count` elements decoded from the (drop-
%% gated) data segment `Bytes`, each `Width` little-endian bytes starting at byte
%% `Offset`. Numeric elements are their raw bit pattern (carder represents both
%% integers and floats as the unsigned bit pattern), so every width decodes with
%% one `binary:decode_unsigned/2`. OOB if the span exceeds the segment.
array_new_data(TypeIdx, Bytes, Offset, Count, Width) ->
    case Offset >= 0 andalso Count >= 0
        andalso Offset + Count * Width =< byte_size(Bytes) of
        %% A data-segment span over-run is spec "out of bounds memory access".
        false -> mem_oob_trap();
        true ->
            new_array(TypeIdx, decode_data_elems(Bytes, Offset, Count, Width))
    end.

%% array.init_data $t $d : copy `Count` elements from data segment `Bytes` (at byte
%% `SrcOff`) into the array at index `DstIdx`. OOB on either range; null-traps.
array_init_data({ref_null}, _DstIdx, _Bytes, _SrcOff, _Count, _Width) ->
    null_array_trap();
array_init_data({gc, Id}, DstIdx, Bytes, SrcOff, Count, Width) ->
    {array, T, Es} = get({gc_obj, Id}),
    %% The ARRAY (destination) range is checked FIRST, then the DATA (source) span —
    %% a both-overflow case reports the array trap (spec ordering, per array_init_data.wast).
    check_range(DstIdx, Count, tuple_size(Es)),
    check_data_range(SrcOff, Count, Width, byte_size(Bytes)),
    Vals = decode_data_elems(Bytes, SrcOff, Count, Width),
    put({gc_obj, Id}, {array, T, write_slice(Es, DstIdx, Vals)}),
    ok.

%% array.new_elem $t $e : a new array of `Count` references taken from the (drop-
%% gated) element segment value list `Refs` starting at index `Offset`.
array_new_elem(TypeIdx, Refs, Offset, Count) ->
    case Offset >= 0 andalso Count >= 0 andalso Offset + Count =< length(Refs) of
        %% An element-segment span over-run is spec "out of bounds table access".
        false -> table_oob_trap();
        true -> new_array(TypeIdx, lists:sublist(Refs, Offset + 1, Count))
    end.

%% array.init_elem $t $e : copy `Count` references from element segment `Refs` (at
%% index `SrcOff`) into the array at index `DstIdx`. OOB on either range; null-traps.
array_init_elem({ref_null}, _DstIdx, _Refs, _SrcOff, _Count) ->
    null_array_trap();
array_init_elem({gc, Id}, DstIdx, Refs, SrcOff, Count) ->
    {array, T, Es} = get({gc_obj, Id}),
    %% ARRAY (destination) range first, then the ELEMENT (source) span — a both-overflow
    %% case reports the array trap (spec ordering, per array_init_elem.wast).
    check_range(DstIdx, Count, tuple_size(Es)),
    check_elem_range(SrcOff, Count, length(Refs)),
    Vals = lists:sublist(Refs, SrcOff + 1, Count),
    put({gc_obj, Id}, {array, T, write_slice(Es, DstIdx, Vals)}),
    ok.

%% Decode `N` little-endian unsigned integers of `W` bytes each from `Bytes` at
%% byte `Off` (bounds already checked by the caller).
decode_data_elems(_Bytes, _Off, 0, _W) -> [];
decode_data_elems(Bytes, Off, N, W) ->
    <<_:Off/binary, Chunk:W/binary, _/binary>> = Bytes,
    [binary:decode_unsigned(Chunk, little)
     | decode_data_elems(Bytes, Off + W, N - 1, W)].

%% Allocate a fresh array object holding `Elems`.
new_array(TypeIdx, Elems) ->
    Id = alloc(),
    put({gc_obj, Id}, {array, TypeIdx, list_to_tuple(Elems)}),
    {gc, Id}.

%% ─────────────────────────────── type matching ────────────────────────────

%% matches(Value, Matcher) -> boolean(). Value is never null here (the null case
%% is handled by the caller). i31 is in the internal hierarchy (i31 <: eq <: any);
%% a heap object matches a concrete set by its stored type index, or an abstract
%% kind by its shape.
matches({i31, _}, {abstract, K}) -> lists:member(K, [i31, eq, any]);
matches({i31, _}, {concrete, _}) -> false;
matches({gc, Id}, Matcher) ->
    {Kind, TypeIdx, _} = get({gc_obj, Id}),
    case Matcher of
        {concrete, Ids} -> lists:member(TypeIdx, Ids);
        {abstract, struct} -> Kind =:= struct;
        {abstract, array} -> Kind =:= array;
        {abstract, eq} -> true;
        {abstract, any} -> true;
        {abstract, _} -> false
    end;
matches({ref_extern, _}, {abstract, extern}) -> true;
matches({ref_extern, _}, {abstract, any}) -> true;
matches(_, _) -> false.

%% ───────────────────────────────── helpers ────────────────────────────────

%% unpack(Raw, Bits, Signed) -> i32 : mask a packed value to `Bits`, sign-extending
%% (to the 32-bit unsigned pattern) when `Signed`.
unpack(Raw, Bits, Signed) ->
    M = Raw band ((1 bsl Bits) - 1),
    case Signed =:= true of
        true -> sign_extend(M, Bits);
        false -> M
    end.

%% Sign-extend the low `Bits` of `M` to the 32-bit unsigned bit pattern.
sign_extend(M, Bits) ->
    SignBit = 1 bsl (Bits - 1),
    ((M bxor SignBit) - SignBit) band 16#FFFFFFFF.

bool_i32(true) -> 1;
bool_i32(false) -> 0.

%% [0, 1, …, Count-1]; empty when Count =< 0.
seq0(Count) when Count =< 0 -> [];
seq0(Count) -> lists:seq(0, Count - 1).

%% Overwrite `Count` elements of `Es` from index `Idx` with `Val`.
fill_slice(Es, Idx, Val, Count) ->
    lists:foldl(fun(K, Acc) -> setelement(Idx + K + 1, Acc, Val) end,
                Es, seq0(Count)).

%% Overwrite `Es` from index `Di` with the values in `Slice` (in order).
write_slice(Es, Di, Slice) ->
    {Res, _} = lists:foldl(
        fun(V, {Acc, K}) -> {setelement(Di + K + 1, Acc, V), K + 1} end,
        {Es, 0}, Slice),
    Res.

check_bounds(Idx, Size) when Idx >= 0, Idx < Size -> ok;
check_bounds(_Idx, _Size) -> array_oob_trap().

check_range(Idx, Count, Size) when Idx >= 0, Count >= 0, Idx + Count =< Size -> ok;
check_range(_Idx, _Count, _Size) -> array_oob_trap().

%% Data-segment byte-span bounds (array.new_data / array.init_data): over-running the
%% DATA segment is spec "out of bounds memory access".
check_data_range(Off, Count, Width, ByteSize)
    when Off >= 0, Count >= 0, Off + Count * Width =< ByteSize -> ok;
check_data_range(_, _, _, _) -> mem_oob_trap().

%% Element-segment span bounds (array.new_elem / array.init_elem): over-running the
%% ELEMENT segment is spec "out of bounds table access".
check_elem_range(Off, Count, Len)
    when Off >= 0, Count >= 0, Off + Count =< Len -> ok;
check_elem_range(_, _, _) -> table_oob_trap().

%% Per-space trap helpers. The spec trap MESSAGE differs by which reference kind / segment
%% space faulted, so each raises a distinct atom (mapped to its spec phrase in the
%% conformance runner's `spec_phrase_of`). Only the message differs — the trap semantics
%% (a genuine WASM trap) are unchanged, and these atoms are reachable ONLY from GC code.
null_trap()        -> erlang:error({wasm_trap, null_reference}).
null_struct_trap() -> erlang:error({wasm_trap, null_structure_reference}).
null_array_trap()  -> erlang:error({wasm_trap, null_array_reference}).
null_i31_trap()    -> erlang:error({wasm_trap, null_i31_reference}).
cast_trap()        -> erlang:error({wasm_trap, cast_failure}).
array_oob_trap()   -> erlang:error({wasm_trap, array_out_of_bounds}).
mem_oob_trap()     -> erlang:error({wasm_trap, memory_out_of_bounds}).
table_oob_trap()   -> erlang:error({wasm_trap, table_out_of_bounds}).
