//// `rt_gc` — the WebAssembly GC seam (this proposal).
////
//// The one module `emit_core` targets for every `Gc` IR node: a `Gc(op, args)`
//// lowers to `call 'twocore@runtime@rt_gc':'<op>'(...)`. Each function here is a
//// thin `@external` binding onto `twocore_rt_gc_ffi`, which owns the per-process
//// arena (the mutable GC heap; see that module for the representation and trap
//// contract). Keeping the seam a distinct Gleam module is what makes GC
//// **opt-in**: the whole-program linker only merges `rt_gc` (and, transitively,
//// the FFI) into programs that actually emit a GC instruction — a plain
//// core-WASM module pulls in none of it.
////
//// Values crossing this boundary are BEAM terms (`Dynamic`): a reference is the
//// arena handle `{gc, Id}`, an i31 `{i31, V}`, null the shared `{ref_null}`
//// sentinel; an i32 result is a plain `Int`. Every function is total except the
//// documented traps (null access, cast failure, array out-of-bounds), which the
//// FFI raises as `{wasm_trap, Kind}`.

import gleam/dynamic.{type Dynamic}

/// `struct.new $t` — allocate a struct of `type_idx` with `fields` (bottom-first).
@external(erlang, "twocore_rt_gc_ffi", "struct_new")
pub fn struct_new(type_idx: Int, fields: List(Dynamic)) -> Dynamic

/// `struct.get $t $f` on a plain (non-packed) field. Traps if `ref` is null.
@external(erlang, "twocore_rt_gc_ffi", "struct_get")
pub fn struct_get(ref: Dynamic, field: Int) -> Dynamic

/// `struct.get_s`/`struct.get_u $t $f` on a packed field → the extended i32.
@external(erlang, "twocore_rt_gc_ffi", "struct_get_packed")
pub fn struct_get_packed(
  ref: Dynamic,
  field: Int,
  bits: Int,
  signed: Bool,
) -> Int

/// `struct.set $t $f`. Traps if `ref` is null.
@external(erlang, "twocore_rt_gc_ffi", "struct_set")
pub fn struct_set(ref: Dynamic, field: Int, value: Dynamic) -> Dynamic

/// `array.new $t` — an array of `count` copies of `elem`.
@external(erlang, "twocore_rt_gc_ffi", "array_new")
pub fn array_new(type_idx: Int, elem: Dynamic, count: Int) -> Dynamic

/// `array.new_fixed $t N` — an array of the given elements (bottom-first).
@external(erlang, "twocore_rt_gc_ffi", "array_new_fixed")
pub fn array_new_fixed(type_idx: Int, elems: List(Dynamic)) -> Dynamic

/// `array.get $t`. Traps on null or out-of-bounds index.
@external(erlang, "twocore_rt_gc_ffi", "array_get")
pub fn array_get(ref: Dynamic, index: Int) -> Dynamic

/// `array.get_s`/`array.get_u $t` on a packed element → the extended i32.
@external(erlang, "twocore_rt_gc_ffi", "array_get_packed")
pub fn array_get_packed(
  ref: Dynamic,
  index: Int,
  bits: Int,
  signed: Bool,
) -> Int

/// `array.set $t`. Traps on null or out-of-bounds index.
@external(erlang, "twocore_rt_gc_ffi", "array_set")
pub fn array_set(ref: Dynamic, index: Int, value: Dynamic) -> Dynamic

/// `array.len` → the element count. Traps if `ref` is null.
@external(erlang, "twocore_rt_gc_ffi", "array_len")
pub fn array_len(ref: Dynamic) -> Int

/// `array.fill $t`. Traps on null or an out-of-range `[index, index+count)`.
@external(erlang, "twocore_rt_gc_ffi", "array_fill")
pub fn array_fill(
  ref: Dynamic,
  index: Int,
  value: Dynamic,
  count: Int,
) -> Dynamic

/// `array.copy $t1 $t2`. Traps on null or an out-of-range span on either side;
/// handles overlapping same-array copies as if via a temporary.
@external(erlang, "twocore_rt_gc_ffi", "array_copy")
pub fn array_copy(
  dst: Dynamic,
  dst_index: Int,
  src: Dynamic,
  src_index: Int,
  count: Int,
) -> Dynamic

/// `ref.i31` — box the low 31 bits of an i32 as an i31 reference.
@external(erlang, "twocore_rt_gc_ffi", "ref_i31")
pub fn ref_i31(value: Int) -> Dynamic

/// `i31.get_s` — the i31 value, sign-extended to i32. Traps if `ref` is null.
@external(erlang, "twocore_rt_gc_ffi", "i31_get_s")
pub fn i31_get_s(ref: Dynamic) -> Int

/// `i31.get_u` — the i31 value, zero-extended to i32. Traps if `ref` is null.
@external(erlang, "twocore_rt_gc_ffi", "i31_get_u")
pub fn i31_get_u(ref: Dynamic) -> Int

/// `ref.test` — 1 if `ref` matches `matcher` (null accepted iff `null_ok`), else 0.
@external(erlang, "twocore_rt_gc_ffi", "ref_test")
pub fn ref_test(ref: Dynamic, matcher: Dynamic, null_ok: Bool) -> Int

/// `ref.cast` — `ref` if it matches `matcher` (null iff `null_ok`), else traps.
@external(erlang, "twocore_rt_gc_ffi", "ref_cast")
pub fn ref_cast(ref: Dynamic, matcher: Dynamic, null_ok: Bool) -> Dynamic

/// `ref.eq` — 1 if the two references are identical, else 0.
@external(erlang, "twocore_rt_gc_ffi", "ref_eq")
pub fn ref_eq(a: Dynamic, b: Dynamic) -> Int

/// `ref.as_non_null` — `ref`, or trap if it is null.
@external(erlang, "twocore_rt_gc_ffi", "ref_as_non_null")
pub fn ref_as_non_null(ref: Dynamic) -> Dynamic

/// `any.convert_extern` — reinterpret an external reference as an internal one.
@external(erlang, "twocore_rt_gc_ffi", "any_convert_extern")
pub fn any_convert_extern(ref: Dynamic) -> Dynamic

/// `extern.convert_any` — reinterpret an internal reference as an external one.
@external(erlang, "twocore_rt_gc_ffi", "extern_convert_any")
pub fn extern_convert_any(ref: Dynamic) -> Dynamic
