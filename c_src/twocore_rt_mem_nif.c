/*
 * twocore_rt_mem_nif.c — the tier-N («nif») linear-memory C core (S15-02, the heart).
 *
 * A real `erl_nif` backend over a RESERVED raw byte buffer managed by an ERTS resource, filling
 * the 16 exports frozen by S15-01 (`c_src/twocore_rt_mem_nif.h` + `src/twocore_rt_mem_nif_ffi.erl`).
 * It is BIT-IDENTICAL to the paged reference `twocore/runtime/rt_mem` for every access — the S15-02
 * per-op `nif ≡ paged ≡ oracle` differential (test/twocore/runtime/rt_mem_nif_test.gleam) is the
 * proof. The Gleam heads (rt_mem_nif.gleam) keep the pdict/record plumbing + the fuel charges and
 * dispatch native-if-`nif_available()`-else-paged-delegate; this C owns ONLY the pure `mem_*` algebra.
 *
 * ─────────────────────────── The security boundary (S3) ───────────────────────────
 *
 * Every CHECKED op bounds-checks IN C BEFORE touching the buffer — a bug here is a genuine HOST
 * ESCAPE (an OOB read/write past the ERTS-owned buffer), which is exactly why tier-N is Unsafe-only.
 * The Gleam head has already combined `ea = addr + offset` as a no-wrap BEAM bignum (MF1), so the C
 * NEVER re-adds addr+offset and the addition cannot wrap here. Because memory64 is live, `ea` may be
 * a full i64, so the bounds check is OVERFLOW-SAFE (MF2): every address/count operand is decoded with
 * `enif_get_uint64` (a FAILED decode — the operand is negative or >= 2^64 — is itself OOB, matching
 * the paged `>= 0 && ea + n <= byte_len` predicate), then checked with GUARDED SUBTRACTIONS that
 * cannot wrap:
 *
 *     if (ea > byte_len)      -> OOB     // no add; cannot overflow
 *     if (n  > byte_len - ea) -> OOB     // byte_len - ea >= 0 here (ea <= byte_len)
 *
 * NEVER the wrap-prone `ea + n > byte_len` (a 64-bit `ea` overflow-wraps past it → an OOB memcpy).
 * NEVER masked mod 2^32. ALWAYS against `byte_len` (the live watermark), never `max_bytes` (the
 * reservation ceiling). Multi-byte stores / fill / copy / init are TRAP-BEFORE-WRITE / all-or-nothing.
 *
 * ─────────────────────────── Conventions honored VERBATIM from rt_mem ───────────────────────────
 *
 *   - LITTLE-endian byte moves; f32/f64 are raw IEEE-bit moves (assembled/emitted byte-by-byte, so
 *     the result is identical on any host endianness — never a BEAM `double` round-trip).
 *   - Sub-word SIGNED loads sign-extend from `bytes*8` to `result_width` and return the UNSIGNED
 *     two's-complement bit pattern in [0, 2^result_width) (rt_mem `decode_signed`); else zero-extend.
 *   - `grow` bumps `byte_len` within the reserved `max_bytes` (a moving watermark, NEVER realloc'd —
 *     outstanding resource identity is stable) and returns the PREVIOUS page count, or -1 if the delta
 *     would exceed `max_bytes`. The reserved tail [byte_len, max_bytes) is pre-zeroed at `fresh` and
 *     never written past `byte_len`, so newly-grown pages read zero for free (a tail-zero invariant
 *     that is part of the security argument).
 *
 * Term shapes (the frozen ABI the Gleam @external heads decode): `{ok, V}` = Gleam `Ok(V)`,
 * `{ok, nil}` = `Ok(Nil)`, `{error, memory_out_of_bounds}` = `Error(MemoryOutOfBounds)`, a bare
 * integer / `nil` for the unchecked heads, `true`/`false` for `nif_available/0`.
 */

#include <erl_nif.h>
#include <string.h>
#include "twocore_rt_mem_nif.h"

/* The fixed WASM page size in bytes (64 KiB) — `byte_len = pages * PAGE_BYTES`. Single-sourced with
 * rt_mem `page_bytes` / the header's page unit. */
#define PAGE_BYTES ((ErlNifUInt64)65536)

/* The resource type (opened in `load`) + the cached atoms. Atom terms are immediate, env-independent
 * and immortal, so static caching is sound and keeps the hot path off `enif_make_atom`. */
static ErlNifResourceType *MEM_RES_TYPE = NULL;
static ERL_NIF_TERM am_ok;
static ERL_NIF_TERM am_error;
static ERL_NIF_TERM am_nil;
static ERL_NIF_TERM am_oob;   /* memory_out_of_bounds */
static ERL_NIF_TERM am_true;
static ERL_NIF_TERM am_false;
static ERL_NIF_TERM am_pong;

/* ─────────────────────────── term helpers ─────────────────────────── */

static ERL_NIF_TERM ok_tuple(ErlNifEnv *env, ERL_NIF_TERM v) {
    return enif_make_tuple2(env, am_ok, v);
}

/* `Ok(Nil)` — the success shape for every mutator that yields no value. */
static ERL_NIF_TERM ok_nil(ErlNifEnv *env) {
    return enif_make_tuple2(env, am_ok, am_nil);
}

/* `Error(MemoryOutOfBounds)` — the single trap shape (the security boundary fired). */
static ERL_NIF_TERM oob(ErlNifEnv *env) {
    return enif_make_tuple2(env, am_error, am_oob);
}

/* Recover this NIF's resource from `t`. Sound because under `mem_tier == Nif` the memory slot is
 * produced SOLELY by this module's `nif_fresh`, so `t` is always one of our resources. */
static int get_mem(ErlNifEnv *env, ERL_NIF_TERM t, twocore_mem_t **out) {
    return enif_get_resource(env, t, MEM_RES_TYPE, (void **)out);
}

/* Sign-extend the `bytes*8`-bit little-endian value `v` to `result_width` bits, returning the
 * UNSIGNED two's-complement bit pattern in [0, 2^result_width) — rt_mem `decode_signed`. When the
 * source width already equals (or exceeds) the result width the value is returned verbatim. All
 * arithmetic is mod 2^64, so the `2^result_width` / `2^bytes*8` terms that reach 2^64 collapse to 0
 * exactly as the bignum math requires. */
static ErlNifUInt64 sign_extend(ErlNifUInt64 v, int bytes, int result_width) {
    int sb = bytes * 8;
    ErlNifUInt64 sign_bit = (sb >= 64) ? ((ErlNifUInt64)1 << 63)
                                       : ((ErlNifUInt64)1 << (sb - 1));
    if (v & sign_bit) {
        ErlNifUInt64 rw = (result_width >= 64) ? 0 : ((ErlNifUInt64)1 << result_width);
        ErlNifUInt64 wm = (sb >= 64) ? 0 : ((ErlNifUInt64)1 << sb);
        return v + rw - wm; /* s + 2^result_width where s = v - 2^(bytes*8) */
    }
    return v;
}

/* ─────────────────────────── the probe + availability exports ─────────────────────────── */

/* nif_ping/0 -> 'pong'. Re-supplied here (the build FFI's verify_ping calls it after attaching THIS
 * .c, so it must be a real NIF, not the shim stub). */
static ERL_NIF_TERM nif_ping(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)env; (void)argc; (void)argv;
    return am_pong;
}

/* nif_available/0 -> true. The real .so is loaded, so the Gleam heads dispatch NATIVE (the shim stub
 * returns `false`, keeping the paged-delegate fallback on a bare BEAM). */
static ERL_NIF_TERM nif_available(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)env; (void)argc; (void)argv;
    return am_true;
}

/* ─────────────────────────── constructors + observers ─────────────────────────── */

/* nif_fresh(MinBytes, MaxBytes) -> Resource. Allocate the reserved buffer once (never realloc'd),
 * zero the WHOLE reservation (so grown pages read zero for free), set the live watermark to MinBytes.
 * The Gleam head computed both counts from the reservation policy, so the C cannot over-commit. */
static ERL_NIF_TERM nif_fresh(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifUInt64 min_bytes, max_bytes;
    if (!enif_get_uint64(env, argv[0], &min_bytes)) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[1], &max_bytes)) return enif_make_badarg(env);
    twocore_mem_t *m = enif_alloc_resource(MEM_RES_TYPE,
                                           sizeof(twocore_mem_t) + (size_t)max_bytes);
    m->byte_len = (size_t)min_bytes;
    m->max_bytes = (size_t)max_bytes;
    if (max_bytes > 0) memset(m->data, 0, (size_t)max_bytes);
    ERL_NIF_TERM term = enif_make_resource(env, m);
    enif_release_resource(m); /* GC now owns the buffer (dtor NULL — inline, freed with the resource). */
    return term;
}

/* nif_size(Resource) -> Pages :: int (byte_len / 65536). */
static ERL_NIF_TERM nif_size(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    twocore_mem_t *m;
    if (!get_mem(env, argv[0], &m)) return enif_make_badarg(env);
    return enif_make_uint64(env, (ErlNifUInt64)m->byte_len / PAGE_BYTES);
}

/* nif_grow(Resource, DeltaPages) -> PrevPages :: int | -1. Bump the watermark within max_bytes; -1
 * (nothing changes) for a negative/oversized delta. No re-zero (the reserved tail is invariantly
 * zero). No fuel charge — the Gleam `grow` wrapper keeps `rt_meter.charge` on the success path. */
static ERL_NIF_TERM nif_grow(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    twocore_mem_t *m;
    ErlNifSInt64 delta;
    if (!get_mem(env, argv[0], &m)) return enif_make_badarg(env);
    if (!enif_get_int64(env, argv[1], &delta)) return enif_make_int(env, -1);
    if (delta < 0) return enif_make_int(env, -1);
    ErlNifUInt64 add = (ErlNifUInt64)delta * PAGE_BYTES;
    ErlNifUInt64 new_len = (ErlNifUInt64)m->byte_len + add;
    /* overflow-safe: reject if the add wrapped OR the new watermark exceeds the reservation. */
    if (new_len < (ErlNifUInt64)m->byte_len || new_len > (ErlNifUInt64)m->max_bytes)
        return enif_make_int(env, -1);
    ErlNifUInt64 prev_pages = (ErlNifUInt64)m->byte_len / PAGE_BYTES;
    m->byte_len = (size_t)new_len;
    return enif_make_uint64(env, prev_pages);
}

/* nif_to_flat(Resource) -> binary. The whole in-bounds image [0, byte_len); the differential hook. */
static ERL_NIF_TERM nif_to_flat(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    twocore_mem_t *m;
    if (!get_mem(env, argv[0], &m)) return enif_make_badarg(env);
    ErlNifBinary out;
    if (!enif_alloc_binary(m->byte_len, &out)) return enif_make_badarg(env);
    if (m->byte_len > 0) memcpy(out.data, m->data, m->byte_len);
    return enif_make_binary(env, &out);
}

/* ─────────────────────────── scalar load / store (the hot path) ─────────────────────────── */

/* nif_load(Resource, Bytes, Signed, ResultWidth, Ea) -> {ok, int} | {error, memory_out_of_bounds}.
 * Assemble `Bytes` little-endian bytes, then sign/zero-extend to ResultWidth. */
static ERL_NIF_TERM nif_load(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    twocore_mem_t *m;
    int bytes, result_width;
    ErlNifUInt64 ea;
    if (!get_mem(env, argv[0], &m)) return enif_make_badarg(env);
    if (!enif_get_int(env, argv[1], &bytes)) return enif_make_badarg(env);
    int is_signed = enif_is_identical(argv[2], am_true);
    if (!enif_get_int(env, argv[3], &result_width)) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[4], &ea)) return oob(env);
    if (ea > (ErlNifUInt64)m->byte_len) return oob(env);
    if ((ErlNifUInt64)bytes > (ErlNifUInt64)m->byte_len - ea) return oob(env);
    ErlNifUInt64 v = 0;
    for (int k = 0; k < bytes; k++)
        v |= (ErlNifUInt64)m->data[ea + k] << (8 * k);
    ErlNifUInt64 result = is_signed ? sign_extend(v, bytes, result_width) : v;
    return ok_tuple(env, enif_make_uint64(env, result));
}

/* nif_store(Resource, Bytes, Ea, Value) -> {ok, nil} | {error, memory_out_of_bounds}. Bounds-check
 * FIRST (trap-before-write / all-or-nothing), then write the low `Bytes` bytes little-endian. */
static ERL_NIF_TERM nif_store(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    twocore_mem_t *m;
    int bytes;
    ErlNifUInt64 ea, value;
    if (!get_mem(env, argv[0], &m)) return enif_make_badarg(env);
    if (!enif_get_int(env, argv[1], &bytes)) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[2], &ea)) return oob(env);
    if (!enif_get_uint64(env, argv[3], &value)) return oob(env);
    if (ea > (ErlNifUInt64)m->byte_len) return oob(env);
    if ((ErlNifUInt64)bytes > (ErlNifUInt64)m->byte_len - ea) return oob(env);
    for (int k = 0; k < bytes; k++)
        m->data[ea + k] = (unsigned char)((value >> (8 * k)) & 0xFF);
    return ok_nil(env);
}

/* ─────────────────────────── init-data + the SIMD byte seam ─────────────────────────── */

/* nif_init_data(Resource, Ea, Data) -> {ok, nil} | {error, memory_out_of_bounds}. Whole-range check,
 * then copy the segment bytes (an empty segment at ea == byte_len succeeds — a no-op). */
static ERL_NIF_TERM nif_init_data(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    twocore_mem_t *m;
    ErlNifUInt64 ea;
    ErlNifBinary data;
    if (!get_mem(env, argv[0], &m)) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[1], &ea)) return oob(env);
    if (!enif_inspect_binary(env, argv[2], &data)) return enif_make_badarg(env);
    ErlNifUInt64 n = (ErlNifUInt64)data.size;
    if (ea > (ErlNifUInt64)m->byte_len) return oob(env);
    if (n > (ErlNifUInt64)m->byte_len - ea) return oob(env);
    if (n > 0) memcpy(m->data + ea, data.data, (size_t)n);
    return ok_nil(env);
}

/* nif_load_bytes(Resource, Ea, N) -> {ok, binary} | {error, memory_out_of_bounds}. The v128 byte
 * seam: read exactly N bytes in ascending-address (little-endian) order. */
static ERL_NIF_TERM nif_load_bytes(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    twocore_mem_t *m;
    ErlNifUInt64 ea, n;
    if (!get_mem(env, argv[0], &m)) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[1], &ea)) return oob(env);
    if (!enif_get_uint64(env, argv[2], &n)) return oob(env);
    if (ea > (ErlNifUInt64)m->byte_len) return oob(env);
    if (n > (ErlNifUInt64)m->byte_len - ea) return oob(env);
    ErlNifBinary out;
    if (!enif_alloc_binary((size_t)n, &out)) return enif_make_badarg(env);
    if (n > 0) memcpy(out.data, m->data + ea, (size_t)n);
    return ok_tuple(env, enif_make_binary(env, &out));
}

/* nif_store_bytes(Resource, Ea, Data) -> {ok, nil} | {error, memory_out_of_bounds}. Whole-run check
 * first (trap-before-write), then write the run in ascending-address order. */
static ERL_NIF_TERM nif_store_bytes(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    twocore_mem_t *m;
    ErlNifUInt64 ea;
    ErlNifBinary data;
    if (!get_mem(env, argv[0], &m)) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[1], &ea)) return oob(env);
    if (!enif_inspect_binary(env, argv[2], &data)) return enif_make_badarg(env);
    ErlNifUInt64 n = (ErlNifUInt64)data.size;
    if (ea > (ErlNifUInt64)m->byte_len) return oob(env);
    if (n > (ErlNifUInt64)m->byte_len - ea) return oob(env);
    if (n > 0) memcpy(m->data + ea, data.data, (size_t)n);
    return ok_nil(env);
}

/* ─────────────────────────── bulk memory (fill / copy / init) ─────────────────────────── */

/* nif_fill(Resource, Dest, Value, Count) -> {ok, nil} | {error, memory_out_of_bounds}. Eager whole
 * range check, then memset the low byte of Value. Fuel stays Gleam-side. */
static ERL_NIF_TERM nif_fill(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    twocore_mem_t *m;
    ErlNifUInt64 dest, value, count;
    if (!get_mem(env, argv[0], &m)) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[1], &dest)) return oob(env);
    if (!enif_get_uint64(env, argv[2], &value)) return oob(env);
    if (!enif_get_uint64(env, argv[3], &count)) return oob(env);
    if (dest > (ErlNifUInt64)m->byte_len) return oob(env);
    if (count > (ErlNifUInt64)m->byte_len - dest) return oob(env);
    if (count > 0) memset(m->data + dest, (int)(value & 0xFF), (size_t)count);
    return ok_nil(env);
}

/* nif_copy(DstRes, SrcRes, Dst, Src, Count) -> {ok, nil} | {error, memory_out_of_bounds}. memmove
 * (overlap-safe), cross-resource when DstRes != SrcRes — BOTH handles are validated before the move.
 * Eager check of BOTH ranges (trap-before-write). */
static ERL_NIF_TERM nif_copy(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    twocore_mem_t *dst, *src;
    ErlNifUInt64 d, s, count;
    if (!get_mem(env, argv[0], &dst)) return enif_make_badarg(env);
    if (!get_mem(env, argv[1], &src)) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[2], &d)) return oob(env);
    if (!enif_get_uint64(env, argv[3], &s)) return oob(env);
    if (!enif_get_uint64(env, argv[4], &count)) return oob(env);
    if (s > (ErlNifUInt64)src->byte_len) return oob(env);
    if (count > (ErlNifUInt64)src->byte_len - s) return oob(env);
    if (d > (ErlNifUInt64)dst->byte_len) return oob(env);
    if (count > (ErlNifUInt64)dst->byte_len - d) return oob(env);
    if (count > 0) memmove(dst->data + d, src->data + s, (size_t)count);
    return ok_nil(env);
}

/* nif_init(Resource, Seg, Dst, Src, Count) -> {ok, nil} | {error, memory_out_of_bounds}. Eager check
 * of BOTH the segment (`Src + Count <= |Seg|` — a dropped/ε segment traps for Count > 0) and the
 * memory, then copy. Named `mem_init` (not `nif_init`) because `ERL_NIF_INIT` reserves the C symbol
 * `nif_init` for the module entry point; the frozen EXPORT is still `"nif_init"` (see nif_funcs). */
static ERL_NIF_TERM mem_init(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    twocore_mem_t *m;
    ErlNifBinary seg;
    ErlNifUInt64 d, s, count;
    if (!get_mem(env, argv[0], &m)) return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &seg)) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[2], &d)) return oob(env);
    if (!enif_get_uint64(env, argv[3], &s)) return oob(env);
    if (!enif_get_uint64(env, argv[4], &count)) return oob(env);
    ErlNifUInt64 seg_size = (ErlNifUInt64)seg.size;
    if (s > seg_size) return oob(env);
    if (count > seg_size - s) return oob(env);
    if (d > (ErlNifUInt64)m->byte_len) return oob(env);
    if (count > (ErlNifUInt64)m->byte_len - d) return oob(env);
    if (count > 0) memcpy(m->data + d, seg.data + s, (size_t)count);
    return ok_nil(env);
}

/* ─────────────────────────── the unchecked fast path (S4) ───────────────────────────
 *
 * nif_load/store_unchecked are nif_load/store MINUS the bounds compare — a raw LE deref/write
 * returning a bare int / nil (no {ok,_}, no error path). SOUND only because the Phase-10
 * loop-versioning guard proved the whole range in-bounds before this arm runs; on tier-N a bug here
 * is a raw OOB access (not a contained wrong value as for paged's sparse map), which is why the tier
 * is Unsafe-only and the guard is load-bearing. S15-02 lands these dead-until-S15-03-routes them. */

static ERL_NIF_TERM nif_load_unchecked(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    twocore_mem_t *m;
    int bytes, result_width;
    ErlNifUInt64 ea;
    if (!get_mem(env, argv[0], &m)) return enif_make_badarg(env);
    if (!enif_get_int(env, argv[1], &bytes)) return enif_make_badarg(env);
    int is_signed = enif_is_identical(argv[2], am_true);
    if (!enif_get_int(env, argv[3], &result_width)) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[4], &ea)) return enif_make_badarg(env);
    ErlNifUInt64 v = 0;
    for (int k = 0; k < bytes; k++)
        v |= (ErlNifUInt64)m->data[ea + k] << (8 * k);
    ErlNifUInt64 result = is_signed ? sign_extend(v, bytes, result_width) : v;
    return enif_make_uint64(env, result);
}

static ERL_NIF_TERM nif_store_unchecked(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    twocore_mem_t *m;
    int bytes;
    ErlNifUInt64 ea, value;
    if (!get_mem(env, argv[0], &m)) return enif_make_badarg(env);
    if (!enif_get_int(env, argv[1], &bytes)) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[2], &ea)) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[3], &value)) return enif_make_badarg(env);
    for (int k = 0; k < bytes; k++)
        m->data[ea + k] = (unsigned char)((value >> (8 * k)) & 0xFF);
    return am_nil;
}

/* ─────────────────────────── NIF registration ─────────────────────────── */

/* Open the resource type (dtor NULL — the buffer is inline in the allocation, so ERTS frees it with
 * the resource on GC) and cache the atoms. CREATE|TAKEOVER so a RELOAD of the shim (the build FFI
 * purges + reloads it, and the test suite reloads several times) succeeds even when resources from a
 * prior load are still live — CREATE alone fails to re-register a name whose type still has live
 * instances (the taken-over layout is identical, single-sourced from the frozen .h). */
static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data; (void)load_info;
    ErlNifResourceType *rt = enif_open_resource_type(
        env, NULL, TWOCORE_RT_MEM_NIF_RESOURCE, NULL,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    if (rt == NULL) return -1;
    MEM_RES_TYPE = rt;
    am_ok = enif_make_atom(env, "ok");
    am_error = enif_make_atom(env, "error");
    am_nil = enif_make_atom(env, "nil");
    am_oob = enif_make_atom(env, "memory_out_of_bounds");
    am_true = enif_make_atom(env, "true");
    am_false = enif_make_atom(env, "false");
    am_pong = enif_make_atom(env, "pong");
    return 0;
}

/* The frozen 16-export table (keystone §3.3): names/arities VERBATIM from the shim, `nif_`-prefixed. */
static ErlNifFunc nif_funcs[] = {
    {"nif_ping", 0, nif_ping, 0},
    {"nif_available", 0, nif_available, 0},
    {"nif_fresh", 2, nif_fresh, 0},
    {"nif_size", 1, nif_size, 0},
    {"nif_grow", 2, nif_grow, 0},
    {"nif_load", 5, nif_load, 0},
    {"nif_store", 4, nif_store, 0},
    {"nif_init_data", 3, nif_init_data, 0},
    {"nif_load_bytes", 3, nif_load_bytes, 0},
    {"nif_store_bytes", 3, nif_store_bytes, 0},
    {"nif_fill", 4, nif_fill, 0},
    {"nif_copy", 5, nif_copy, 0},
    {"nif_init", 5, mem_init, 0},
    {"nif_to_flat", 1, nif_to_flat, 0},
    {"nif_load_unchecked", 5, nif_load_unchecked, 0},
    {"nif_store_unchecked", 4, nif_store_unchecked, 0}
};

/* The module atom is the SHIM (`twocore_rt_mem_nif_ffi`), NOT the .so basename (keystone §3.3): load_nif
 * attaches to the module in whose code it runs. */
ERL_NIF_INIT(twocore_rt_mem_nif_ffi, nif_funcs, load, NULL, NULL, NULL)
