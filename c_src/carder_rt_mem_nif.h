/*
 * carder_rt_mem_nif.h — the FROZEN tier-N («nif») linear-memory resource ABI.
 *
 * OWNED BY S15-01 (the keystone). This header is the single frozen surface that BOTH the C core
 * (c_src/carder_rt_mem_nif.c, written by S15-02) AND the Gleam heads
 * (src/carder/runtime/rt_mem_nif.gleam, re-bodied by S15-02) bind to. The keystone DEFINES the
 * layout + the per-operation contract; it implements NONE of the ops (only the throwaway `nif_ping`
 * probe, compiled from a source embedded in test/carder_rt_mem_nif_build_ffi.erl, ever touches it
 * this unit). S15-02 fills the ops over exactly this struct.
 *
 * ─────────────────────────────── The resource: a RESERVED raw byte buffer ───────────────────────────────
 *
 * The tier-N linear memory is a single `enif_alloc_resource`'d block whose flexible `data[]` array
 * IS the raw WASM linear memory. RESERVATION model (Phase-15 open seams #2/#3, resolved): the buffer
 * is sized to `max_bytes` ONCE at `nif_fresh` and is NEVER realloc'd — `grow` only bumps the
 * `byte_len` watermark inside `[0, max_bytes]`, so outstanding resource identity / raw pointers are
 * never invalidated (`enif_realloc_resource` is deliberately NOT used). `max_bytes` therefore reuses
 * the atomics-tier reservation caps — the tier RESERVES; it cannot back a 2^48 sparse memory.
 */

#ifndef CARDER_RT_MEM_NIF_H
#define CARDER_RT_MEM_NIF_H

#include <stddef.h>

/*
 * The tier-N linear-memory resource.
 *
 *   - byte_len : logical size in bytes (= pages * 65536); the grow watermark. `data[0 .. byte_len)`
 *                is the live memory; `data[byte_len .. max_bytes)` is reserved-and-zero.
 *   - max_bytes: reserved capacity ceiling; `grow` FAILS (returns -1) when it would exceed this.
 *   - data     : the raw byte buffer (a C flexible array member). Allocated as
 *                `sizeof(carder_mem_t) + max_bytes` via `enif_alloc_resource`.
 */
typedef struct {
    size_t byte_len;      /* logical size in bytes (= pages * 65536); the grow watermark.        */
    size_t max_bytes;     /* reserved capacity ceiling; grow FAILS (-1) past this.               */
    unsigned char data[]; /* the raw byte buffer; [0,byte_len) live, [byte_len,max_bytes) reserved-zero. */
} carder_mem_t;

/*
 * The `enif_open_resource_type` name (frozen). S15-02's `.c` opens the resource type under this name
 * in its `load` callback; the embedded `nif_ping` probe opens it too, so this name is exercised live
 * by the keystone build test.
 */
#define CARDER_RT_MEM_NIF_RESOURCE "carder_rt_mem_nif_resource"

/*
 * ─────────────────────── FROZEN per-operation ABI (the C core must honor VERBATIM) ───────────────────────
 *
 * The op bodies are `static` C functions registered via `nif_funcs[]`, so this header needs no
 * per-op C prototype — the authoritative per-op contract is the Erlang-visible ABI table below,
 * which BOTH the C author (nif_funcs[]) and the Gleam author (@external heads) read as one frozen
 * surface. Every export is `nif_`-prefixed so no name collides with a BEAM auto-imported BIF
 * (`size`/`init`/`copy`/`fill`). The `ERL_NIF_INIT` module atom is `carder_rt_mem_nif_ffi` (the
 * shim module), NOT `carder_rt_mem_nif` — `load_nif` attaches NIFs to the module in whose code it
 * runs, and the Gleam @externals target `"carder_rt_mem_nif_ffi"`.
 *
 *   nif_ping/0                                          -> 'pong'                                  (keystone probe only)
 *   nif_available/0                                     -> bool (true only when the .so is loaded)
 *   nif_fresh/2  (ByteLen, MaxBytes)                    -> Resource
 *   nif_size/1   (Resource)                             -> Pages :: int  (byte_len / 65536)
 *   nif_grow/2   (Resource, DeltaPages)                 -> PrevPages :: int | -1
 *   nif_load/5   (Resource, Bytes, Signed, ResultWidth, Ea) -> {ok, int} | {error, memory_out_of_bounds}
 *   nif_store/4  (Resource, Bytes, Ea, Value)           -> ok | {error, memory_out_of_bounds}
 *   nif_init_data/3 (Resource, Ea, Data :: binary)      -> ok | {error, memory_out_of_bounds}
 *   nif_load_bytes/3 (Resource, Ea, N)                  -> {ok, binary} | {error, memory_out_of_bounds}
 *   nif_store_bytes/3 (Resource, Ea, Data :: binary)    -> ok | {error, memory_out_of_bounds}
 *   nif_fill/4   (Resource, Dest, Value, Count)         -> ok | {error, memory_out_of_bounds}
 *   nif_copy/5   (DstRes, SrcRes, Dst, Src, Count)      -> ok | {error, memory_out_of_bounds}
 *   nif_init/5   (Resource, Seg :: binary, Dst, Src, Count) -> ok | {error, memory_out_of_bounds}
 *   nif_to_flat/1 (Resource)                            -> binary (whole in-bounds image; tests only)
 *   nif_load_unchecked/5  (Resource, Bytes, Signed, ResultWidth, Ea) -> int   (S15-02 fills; no bounds compare)
 *   nif_store_unchecked/4 (Resource, Bytes, Ea, Value)  -> ok                   (S15-02 fills; raw deref)
 *
 * 14 memory ops + nif_ping + nif_available = 16 frozen exports. The `_at` multi-memory twins and the
 * `t_*` threaded twins need NO separate NIFs (the Gleam head picks the resource / rebinds the record);
 * `fresh64` reuses `nif_fresh` (the Gleam head computes ByteLen/MaxBytes).
 *
 * ─────────────────────── FROZEN semantic invariants (a bug here is a genuine HOST ESCAPE) ───────────────────────
 *
 *   - Byte moves are LITTLE-endian. f32/f64 are RAW IEEE-bit moves (never a BEAM `double` round-trip).
 *   - Sub-word SIGNED loads sign-extend to `result_width` and return the unsigned two's-complement bit
 *     pattern in `[0, 2^result_width)`; else zero-extend. (Mirrors the paged reference `rt_mem`.)
 *   - The effective address `Ea` is COMBINED Gleam-side as a no-wrap BEAM bignum (`ea = addr + offset`);
 *     the C NEVER re-adds addr+offset, so the addition cannot wrap in C. The C decodes `Ea` with
 *     `enif_get_uint64` (a failed decode — `Ea >= 2^64` — is itself OOB) and bounds-checks with
 *     GUARDED SUBTRACTIONS: the trap condition is exactly `Ea + n > byte_len` computed overflow-safe
 *     (i.e. `Ea > byte_len || n > byte_len - Ea`) -> {error, memory_out_of_bounds}. This is THE
 *     security boundary — bounds-checked IN C, wrap-safe, BEFORE any byte is touched. Multi-byte
 *     stores / fill / copy / init are TRAP-BEFORE-WRITE / all-or-nothing.
 *   - `grow` bumps `byte_len` within the reserved `max_bytes`, zero-filling the new region, and
 *     returns the PREVIOUS page count, or -1 if the delta would exceed `max_bytes`.
 */

#endif /* CARDER_RT_MEM_NIF_H */
