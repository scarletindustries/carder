//// End-to-end execution tests for the WebAssembly GC proposal: a `wasm-tools`-
//// built GC module is compiled all the way to BEAM (`embed.compile`), instantiated,
//// and its exports invoked — proving the decode → validate → lower → emit → `rt_gc`
//// arena path runs and computes the spec-correct results. Each export returns an
//// i32 (so the result crosses the host boundary) but exercises struct/array/i31/
//// ref.test/ref.eq internally, including mutation through the arena.

import carder/embed
import gleeunit/should
import simplifile

fn instance() {
  let assert Ok(wasm) =
    simplifile.read_bits("test/carder/frontend/wasm/gc_fixtures/gcrun.wasm")
  let assert Ok(compiled) = embed.compile(wasm)
  let no_host = fn(_capability, _name, _args) { [] }
  let assert Ok(inst) = embed.instantiate(compiled, no_host)
  inst
}

/// struct.new / struct.set (mutation seen through the handle) / struct.get:
/// new {10,32}, set field0 := 5, read 5 + 32 = 37.
pub fn gc_struct_roundtrip_test() {
  let inst = instance()
  embed.invoke(inst, "struct_test", []) |> should.equal(Ok([37]))
  embed.stop(inst)
}

/// array.new (4×7) / array.set idx2 := 100 / array.get + array.len: 100 + 4 = 104.
pub fn gc_array_roundtrip_test() {
  let inst = instance()
  embed.invoke(inst, "array_test", []) |> should.equal(Ok([104]))
  embed.stop(inst)
}

/// Packed i8 element: store 511 (0x1FF), read unsigned → 0xFF, and 0xFF = 255.
pub fn gc_packed_element_test() {
  let inst = instance()
  embed.invoke(inst, "packed_test", []) |> should.equal(Ok([255]))
  embed.stop(inst)
}

/// ref.i31 then i31.get_s round-trips a small non-negative value unchanged.
pub fn gc_i31_roundtrip_test() {
  let inst = instance()
  embed.invoke(inst, "i31_test", [100]) |> should.equal(Ok([100]))
  embed.stop(inst)
}

/// ref.test: a `$pt` matches `(ref $pt)` (1) but not `(ref $ints)` (0) → 10.
pub fn gc_ref_test_test() {
  let inst = instance()
  embed.invoke(inst, "test_test", []) |> should.equal(Ok([10]))
  embed.stop(inst)
}

/// ref.eq: identity holds for the same handle (1) and fails for two distinct
/// `struct.new`s with equal fields (0) → 10.
pub fn gc_ref_eq_test() {
  let inst = instance()
  embed.invoke(inst, "eq_test", []) |> should.equal(Ok([10]))
  embed.stop(inst)
}

fn branch_instance() {
  let assert Ok(wasm) =
    simplifile.read_bits("test/carder/frontend/wasm/gc_fixtures/gcbranch.wasm")
  let assert Ok(compiled) = embed.compile(wasm)
  let no_host = fn(_capability, _name, _args) { [] }
  let assert Ok(inst) = embed.instantiate(compiled, no_host)
  inst
}

/// br_on_cast success: an `anyref` holding a `$pt` downcasts and branches, then
/// reads field 0 = 42.
pub fn gc_br_on_cast_hit_test() {
  let inst = branch_instance()
  embed.invoke(inst, "cast_hit", []) |> should.equal(Ok([42]))
  embed.stop(inst)
}

/// br_on_cast miss: an `anyref` holding an i31 fails the `$pt` cast, falls through
/// → -1 (0xFFFFFFFF unsigned).
pub fn gc_br_on_cast_miss_test() {
  let inst = branch_instance()
  embed.invoke(inst, "cast_miss", []) |> should.equal(Ok([4_294_967_295]))
  embed.stop(inst)
}

/// br_on_null: a non-null `$pt` falls through to read field 0 = 7; a null branches
/// away → -1.
pub fn gc_br_on_null_test() {
  let inst = branch_instance()
  embed.invoke(inst, "brnull", [1]) |> should.equal(Ok([7]))
  embed.invoke(inst, "brnull", [0]) |> should.equal(Ok([4_294_967_295]))
  embed.stop(inst)
}

fn callref_instance() {
  let assert Ok(wasm) =
    simplifile.read_bits("test/carder/frontend/wasm/gc_fixtures/gccallref.wasm")
  let assert Ok(compiled) = embed.compile(wasm)
  let no_host = fn(_capability, _name, _args) { [] }
  let assert Ok(inst) = embed.instantiate(compiled, no_host)
  inst
}

/// call_ref through a ref.func: apply_add(3, 4) calls $add → 7.
pub fn gc_call_ref_test() {
  let inst = callref_instance()
  embed.invoke(inst, "apply_add", [3, 4]) |> should.equal(Ok([7]))
  embed.stop(inst)
}

/// call_ref through a runtime-chosen funcref (a minimal vtable dispatch): flag 1 →
/// add (10+3=13), flag 0 → sub (10-3=7).
pub fn gc_call_ref_dispatch_test() {
  let inst = callref_instance()
  embed.invoke(inst, "dispatch", [1, 10, 3]) |> should.equal(Ok([13]))
  embed.invoke(inst, "dispatch", [0, 10, 3]) |> should.equal(Ok([7]))
  embed.stop(inst)
}

fn seg_instance() {
  let assert Ok(wasm) =
    simplifile.read_bits("test/carder/frontend/wasm/gc_fixtures/gcseg.wasm")
  let assert Ok(compiled) = embed.compile(wasm)
  let no_host = fn(_capability, _name, _args) { [] }
  let assert Ok(inst) = embed.instantiate(compiled, no_host)
  inst
}

/// array.new_data on a packed i8 array: data "\01\02\03\04" → element 2 (get_u) = 3.
pub fn gc_array_new_data_i8_test() {
  let inst = seg_instance()
  embed.invoke(inst, "new_data_i8", []) |> should.equal(Ok([3]))
  embed.stop(inst)
}

/// array.new_data on an i32 array: two little-endian i32s (10, 20) → 30.
pub fn gc_array_new_data_i32_test() {
  let inst = seg_instance()
  embed.invoke(inst, "new_data_i32", []) |> should.equal(Ok([30]))
  embed.stop(inst)
}

/// array.init_data: [0,0,0] initialized at [1..2] from the data segment → [0,1,2],
/// element 1 + element 2 = 3.
pub fn gc_array_init_data_test() {
  let inst = seg_instance()
  embed.invoke(inst, "init_data", []) |> should.equal(Ok([3]))
  embed.stop(inst)
}

/// array.new_elem: an array of funcrefs [add, sub] from an element segment; calling
/// element 0 (add) with (3, 4) = 7.
pub fn gc_array_new_elem_test() {
  let inst = seg_instance()
  embed.invoke(inst, "new_elem", []) |> should.equal(Ok([7]))
  embed.stop(inst)
}

/// array.init_elem: an array of nulls, element 0 initialized from the segment's
/// element 1 (sub); calling it with (10, 3) = 7.
pub fn gc_array_init_elem_test() {
  let inst = seg_instance()
  embed.invoke(inst, "init_elem", []) |> should.equal(Ok([7]))
  embed.stop(inst)
}

/// return_call_ref: a tail-recursive sum(n) = n + (n-1) + … + 0 through a funcref.
/// sum(10) = 55; a deep count (50000) completes, exercising the constant-stack tail call.
pub fn gc_return_call_ref_test() {
  let assert Ok(wasm) =
    simplifile.read_bits("test/carder/frontend/wasm/gc_fixtures/gctail.wasm")
  let assert Ok(compiled) = embed.compile(wasm)
  let no_host = fn(_capability, _name, _args) { [] }
  let assert Ok(inst) = embed.instantiate(compiled, no_host)
  embed.invoke(inst, "sum", [10]) |> should.equal(Ok([55]))
  // 50000*50001/2 = 1250025000 (fits in an unsigned i32) — a proper tail call
  // returns it in constant stack rather than overflowing.
  embed.invoke(inst, "sum", [50_000]) |> should.equal(Ok([1_250_025_000]))
  embed.stop(inst)
}

/// Regression (verifier finding): ref.is_null on a `ref.func` result must be
/// accepted (a non-null (ref $t) is a valid (ref null $t) operand) and yield 0.
pub fn gc_ref_is_null_of_ref_func_test() {
  let assert Ok(wasm) =
    simplifile.read_bits("test/carder/frontend/wasm/gc_fixtures/gcrefnull.wasm")
  let assert Ok(compiled) = embed.compile(wasm)
  let no_host = fn(_capability, _name, _args) { [] }
  let assert Ok(inst) = embed.instantiate(compiled, no_host)
  embed.invoke(inst, "isnull", []) |> should.equal(Ok([0]))
  embed.stop(inst)
}
