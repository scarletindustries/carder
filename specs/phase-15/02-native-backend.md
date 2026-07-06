# S15-02 — The native backend: the checked C `erl_nif` core + the byte-identical Gleam `@external` rewrite

> **Status:** scoped, awaiting build. **Owner:** S15-02 (the heart — Wave A, behind `«NIF-BUILD-FROZEN»`).
> **Consumes:** the S15-01 freeze (the `c_src/twocore_rt_mem_nif.h` resource-struct + op ABI, the
> `src/twocore_rt_mem_nif_ffi.erl` shim export table + `-on_load`/`.so`-name convention, and the
> `test/twocore_rt_mem_nif_build_ffi.erl` `cc`-gated compile+`load_nif` harness signature — proven live by
> `nif_ping`). **Read order:** [`00-overview.md`](00-overview.md) → the distilled codebase map
> (`brief-phase15-cnif.md`) → the S15-01 keystone doc → this doc. All prior-phase decisions and the
> permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold.
>
> This unit fills the frozen shim with a **real C NIF over a reserved raw byte buffer** and swaps every
> `rt_mem_nif.gleam` body to a **native-if-loaded-else-paged-delegate dispatch** (MF3) — the native arm
> calls the shim `@external`, the fallback arm keeps delegating to `rt_mem` on a bare BEAM — **preserving
> every frozen head byte-for-byte** so `emit_core` routes to tier-N unchanged. It also lands the
> `*_unchecked` fast-path heads (Gleam + C) per the overview's S15-02/S15-03 split. The proof is a
> **per-op `nif ≡ paged ≡ oracle` differential**, `cc`-gated and skip-categorized when no toolchain is
> present. **Default output (tier-P/tier-O) is untouched; tier-N is opt-in.**
>
> **Honors S2** (bit-identical native backend; the differential is the proof), **S3** (the C bounds-check
> is the security boundary), **S4** (owns the unchecked heads Gleam+C — S15-03 owns only the `emit_core`
> whitelist entry + the `emit_unchecked` test flip), **S6** (`cc`-gated / categorized-skip / never a false
> green), **S7** (correctness = the differential + the fuzz, not goldens), **S8** (honest scope: linear
> memory only, test-time gated `.so`, Unsafe-only). **Does not weaken S5** — it touches none of the four
> Safe-forbidden gate sites.

---

## §1. Goal

Replace the paged-delegating bodies of `src/twocore/runtime/rt_mem_nif.gleam` with a genuine `erl_nif` C
backend (`c_src/twocore_rt_mem_nif.c`) managing a reserved raw byte buffer via an ERTS resource, such that
tier-N produces **bit-pattern-identical** values and **identical traps** to the paged reference
(`twocore/runtime/rt_mem`) and the flat-binary oracle — for the Cell and Threaded families, the `_at`
multi-memory twins, the bulk ops, and the SIMD byte seam — and expose the `*_unchecked` fast path tier-N
currently lacks. Concretely:

- **A new C core** (`c_src/twocore_rt_mem_nif.c`) implementing the checked pure-memory algebra over an
  `enif_alloc`-d **reserved** buffer, honoring the paged conventions verbatim (little-endian byte moves,
  the combined no-wrap effective address `ea` decoded as `u64`, sub-word sign-extension to `result_width`,
  trap-before-write multi-byte stores, `grow` as a watermark bump within the reserved max) — with the
  **overflow-safe guarded-subtraction** bounds check (`ea > byte_len || n > byte_len - ea`, memory64-safe,
  MF2) **in C** as the security boundary (S3).
- **The Gleam rewrite** — swap all 37 frozen bodies to a **native-if-`nif_available()`-else-`rt_mem`
  dispatch** (MF3): the native arm sources the resource handle (from the pdict cell / the threaded record /
  the mem-index slot) and calls the `nif_`-prefixed `@external`s on that explicit handle (passing the
  combined `ea = addr + offset`, MF1), keeping the fuel charges and trap-routing Gleam-side; the fallback
  arm keeps delegating to `rt_mem` so a bare BEAM still runs. **Every head is preserved** so `emit_core`'s
  `seam_call(mem_module, "<op>", …)` routing is unchanged.
- **The unchecked heads** — add `load_unchecked` / `store_unchecked` (cell) and `t_load_unchecked` /
  `t_store_unchecked` (threaded) as Gleam heads + C bodies (a raw deref, bounds compare elided). Per the
  overview §4 split note, S15-02 owns these heads (Gleam + C); **S15-03 owns only** the one-line
  `emit_core.mem_supports_unchecked` whitelist entry and the `emit_unchecked_test` flip.
- **The differential** — rewire `test/twocore/runtime/rt_mem_nif_test.gleam` so its existing 3-way
  `nif ≡ paged ≡ oracle` differential runs against the **real NIF**, gated on a successful test-time
  `cc` build+`load_nif` and **skip-categorized** when no toolchain is present (S6).

**Native-when-loaded, paged-delegate-otherwise (MF3).** "Bit-identical native" means **native when the
`.so` is loaded** (CI, and packaged deployments) — the differential proves `native == paged` when `cc` is
present; **paged-delegate otherwise** (a bare BEAM / `cc`-absent host), where each head falls back to
`rt_mem` and is byte-identical by construction. This preserves the Phase-11 `runs_anywhere` property: the
tier runs on a bare BEAM with no NIF and **no per-file skip-gating**, keeping `conformance_test` /
`mem_oracle_differential_test` / `pipeline_tier_test` (unowned by Phase 15) working unchanged.

Implements the load-bearing part of the phase: everything downstream (S15-03 unchecked wiring, S15-04
fuzz + full `cell_nif` matrix, S15-05 benchmark) binds to the ops this unit lands green.

---

## §2. Depends on / Produces

**Depends on (frozen upstream, `«NIF-BUILD-FROZEN»` — S15-01):**

- `c_src/twocore_rt_mem_nif.h` — the resource-struct layout and the per-operation ABI contract this unit's
  `.c` implements and the Gleam `@external`s bind to. S15-02 `#include`s it; it does **not** edit it.
- `src/twocore_rt_mem_nif_ffi.erl` — the shim: `-on_load` → `erlang:load_nif(SoPath, 0)`, one
  `erlang:nif_error(nif_not_loaded)` stub per exported NIF, with the exact export **names/arities** the
  Gleam `@external`s call (§3.2 export table). S15-02's `.c` supplies the `ERL_NIF_INIT` whose module name
  equals this shim module and whose `nif_funcs` match this export table. S15-02 does **not** edit the shim
  (S15-01 froze it; if a new export is needed the arity was reserved at freeze — see §7).
- `test/twocore_rt_mem_nif_build_ffi.erl` — the `os:find_executable("cc")` gate (fallback `"gcc"`) + the
  `run_port` `cc -shared -fPIC` compile-to-tempdir + `erlang:load_nif`, skip-categorized on absence,
  `erl_nif.h` located via the frozen `erts_include/0` resolver (the candidate-list, first-with-`erl_nif.h`
  logic — keystone §3.5, **not** the bare `code:lib_dir(erts, include)`, which returns a header-less path on
  homebrew OTP 29). S15-02's differential test **calls** this gate;
  it does not edit it. Mirrors `test/twocore_bindings_ffi.erl` (`which/1` `:52-56`, `compile_load_*`
  `:114-142/:157-184`, `run_port` `:277-292`).

**Read-only references (conventions the C impl must match verbatim — `src/twocore/runtime/rt_mem.gleam`):**
`in_bounds` `:1473-1475` (`ea >= 0 && ea + n <= byte_len`, `ea` a bignum, never masked), `encode_le`
`:1480-1483`, `decode_unsigned` `:1487-1491`, `decode_signed` `:1498-1505` (sign-extend to `result_width`,
return the unsigned two's-complement pattern in `[0, 2^result_width)`), `mem_store` trap-before-write
`:810-825`, `mem_load_unchecked` `:832-845`, `mem_store_unchecked` `:850-858`; `page_bytes = 65536`,
`byte_len = pages * 65536`. Reservation semantics reused from `rt_mem_atomics.reservation` `:140-151` /
`reservation64` `:168-179` (S2 — the tier reuses the atomics reservation caps).

**Produces:** the real tier-N native backend — the C core, the byte-identical Gleam bindings (checked +
unchecked), and the per-op differential green (or categorized-skip when no `cc`). **Unblocks** S15-03
(the `emit_core` whitelist + test flip bind to the unchecked heads this unit lands), S15-04 (the fuzz +
full `cell_nif` matrix bind to the checked ops + `to_flat`), and S15-05 (the benchmark measures the real
nif column). **Does not touch** `MemTier`, `mem_module_for`, `validate_binding`, `instantiate`, the
`--link` `LinkTierNif` gate, or any `emit_mem_*` seam (the tier stays a build-time module swap; S5 gates
preserved verbatim).

---

## §3. What it owns + design

**Owned files (D1) — this unit is the sole owner of each:**

- new `c_src/twocore_rt_mem_nif.c` — the checked + unchecked C memory core.
- `src/twocore/runtime/rt_mem_nif.gleam` — swap all bodies to `@external` (checked + unchecked), preserving
  every frozen head.
- `test/twocore/runtime/rt_mem_nif_test.gleam` — the per-op `nif ≡ paged ≡ oracle` differential, gated on
  `cc`.

**Deliberately NOT owned** (per the overview §4 map + the S15-02/S15-03 split note):
`src/twocore/backend/emit_core.gleam` (`mem_supports_unchecked` whitelist `:1780` — **S15-03**),
`test/twocore/backend/emit_unchecked_test.gleam` (`nif_falls_back_to_the_checked_path_test` `:77-85` flip —
**S15-03**), `test/twocore/tier/combos.gleam` (`cell_nif` native wiring — **S15-04**),
`test/twocore/runtime/rt_mem_nif_safety_test.gleam` (the bounds fuzz — **S15-04**), and every
Safe-forbidden gate site (unchanged — S5).

### 3.1 The architecture — the NIF is the pure core; Gleam keeps the plumbing + fuel

`rt_mem` is structured as a **pure `mem_*` core over an explicit `Mem`** (`mem_load`/`mem_store`/…) plus
**cell wrappers** (`current_mem()`/`current_mem_at(idx)` read the pdict via `rt_state.mem_at`; mutators
write back via `rt_state.with_mem_at`) and **threaded wrappers** (project `st.mem` via `rt_state.mem`;
mutators rebind via `rt_state.with_mem`). The fuel charges (`rt_meter.charge`) live in the wrappers, never
in the pure core.

S15-02 mirrors this exactly, with **the C NIF replacing only the pure `mem_*` algebra**:

- The **NIF exports operate on an explicit resource handle** (a `Dynamic` — the ERTS resource term), just
  as `mem_load(m, …)` takes an explicit `Mem`. §3.2 is the export table.
- The **Gleam heads keep the pdict/record/mem-index plumbing and the fuel charges**, and call the NIF
  `@external`s on the sourced handle. So `grow`/`fill`/`copy`/`init` keep their exact `rt_meter.charge(…)`
  calls Gleam-side (metering byte-identical to paged/atomics — an untrusted module cannot allocate to the
  cap with zero CPU accounting), and the tier module still **never** calls `rt_trap` (the `emit_core` seam
  does the `{ok,_}`/`{error,R}` → raise, `rt_mem_nif.gleam:48-49`). When the `.so` is **not** loaded
  (`nif_available()` false — a bare BEAM / `cc`-absent host), the same head delegates to `rt_mem` instead
  (MF3), so the plumbing + fuel are identical on both arms.
- **The resource is mutated in place** and its identity is stable across every op including `grow` (a
  watermark bump inside the struct — §3.3, no `enif_realloc`, resolving overview open seam 3), so the cell
  mutators need **no write-back** and the threaded mutators return the rebound record carrying the **same**
  handle. This is exactly the "mutable resource, same handle" property the skeleton heads were written to
  admit (`rt_mem_nif.gleam:176-177/198-200`) — the signatures do not change, which is why the native impl
  needs no seam change.

**Coercion soundness (S3, unchanged):** under `mem_tier == Nif` the cell / threaded `mem` slot is produced
**solely** by this module's `fresh`/`fresh64` (→ `nif_fresh`), so the opaque `Dynamic` there is always this
NIF's resource; `enif_get_resource` against this module's resource type is therefore sound.

### 3.2 The frozen shim export table (the NIF core the `.c` implements)

The shim is `twocore_rt_mem_nif_ffi` (the module whose `-on_load` runs `erlang:load_nif`); the `.so` file
basename is `twocore_rt_mem_nif`. The `.c` supplies:

```c
ERL_NIF_INIT(twocore_rt_mem_nif_ffi, nif_funcs, load, NULL, upgrade, unload)
```

— the **first argument matches the S15-01-frozen shim module name** (the module doing the load, not the
`.so` basename), and `nif_funcs` matches the **S15-01-frozen names/arities verbatim** (keystone §3.3 — the
`nif_`-prefixed table; the `nif_` prefix avoids the autoimport collisions bare `size`/`init`/`copy`/`fill`
would hit, MF5). This table **restates that frozen list; it does not re-spell it.** Every load/store head
takes a **single combined `Ea`** (the Gleam head computes `ea = addr + offset` as a no-wrap BEAM bignum —
§3.3/§3.4, MF1); the C never re-adds. Gleam types are shown as they appear at the Erlang term boundary.

| Export (name/arity) | Erlang term args | Returns | Gleam heads that call it |
|---|---|---|---|
| `nif_fresh/2` | `MinBytes:int, ReserveBytes:int` | resource | `fresh`, `fresh64` |
| `nif_load/5` | `Res, Bytes, Signed:bool, ResultWidth, Ea` | `{ok,int}` \| `{error,memory_out_of_bounds}` | `load`, `load_at`, `t_load`, `t_load_at` |
| `nif_store/4` | `Res, Bytes, Ea, Value` | `{ok,nil}` \| `{error,memory_out_of_bounds}` | `store`, `store_at`, `t_store`, `t_store_at` |
| `nif_size/1` | `Res` | `int` (pages) | `size`, `size_at`, `t_size`, `t_size_at` |
| `nif_grow/2` | `Res, Delta` | `int` (prev pages, or `-1`) | `grow`, `grow_at`, `t_grow`, `t_grow_at` |
| `nif_init_data/3` | `Res, Ea, Bytes:binary` | `{ok,nil}` \| `{error,memory_out_of_bounds}` | `init_data`, `init_data_at`, `t_init_data`, `t_init_data_at` |
| `nif_fill/4` | `Res, Dest, Value, Count` | `{ok,nil}` \| `{error,memory_out_of_bounds}` | `fill`, `t_fill` |
| `nif_copy/5` | `DstRes, SrcRes, Dst, Src, Count` | `{ok,nil}` \| `{error,memory_out_of_bounds}` | `copy`, `t_copy` |
| `nif_init/5` | `Res, Seg:binary, Dst, Src, Count` | `{ok,nil}` \| `{error,memory_out_of_bounds}` | `init`, `t_init` |
| `nif_load_bytes/3` | `Res, Ea, N` | `{ok,binary}` \| `{error,memory_out_of_bounds}` | `load_bytes`, `load_bytes_at`, `t_load_bytes`, `t_load_bytes_at` |
| `nif_store_bytes/3` | `Res, Ea, Bytes:binary` | `{ok,nil}` \| `{error,memory_out_of_bounds}` | `store_bytes`, `store_bytes_at`, `t_store_bytes`, `t_store_bytes_at` |
| `nif_to_flat/1` | `Res` | `binary` | `to_flat` (differential hook) |
| `nif_load_unchecked/5` | `Res, Bytes, Signed:bool, ResultWidth, Ea` | `int` | `load_unchecked`, `t_load_unchecked` |
| `nif_store_unchecked/4` | `Res, Bytes, Ea, Value` | `nil` | `store_unchecked`, `t_store_unchecked` |

These 14 memory ops, plus the keystone's `nif_ping/0` and the fallback probe `nif_available/0` (§3.4, MF3),
are the **16 frozen exports** (keystone §3.3). The many Gleam heads collapse onto the 14 because the
head↔head difference is purely **where the handle comes from** (pdict cell / threaded record / mem-index
slot) and how the combined `Ea` is computed, not the pure op. The **term shapes are the frozen ABI**:
`Ok(x)` = `{ok, x}`, `Error(MemoryOutOfBounds)` = `{error, memory_out_of_bounds}` (a nullary Gleam
constructor compiles to the snake_case atom), `Nil` = the atom `nil`, a Gleam `Bool` = the `true`/`false`
atom, a `BitArray` = an Erlang binary. §3.4 pins the codec/atom details; §5 test 5 asserts the atom
round-trips so an ABI drift is caught, not silently mis-decoded.

### 3.3 `c_src/twocore_rt_mem_nif.c` — the checked C core (the security boundary, S3)

**Resource layout** (from the frozen `.h`), a flexible-array struct inline in the resource allocation:

```c
typedef struct { size_t byte_len; size_t max_bytes; unsigned char data[]; } twocore_mem;
```

`byte_len` = the current logical length the bounds-check uses (`= pages * 65536`); `max_bytes` = the
reserved physical ceiling. A module-static `ErlNifResourceType *MEM_RES_TYPE` is created in the `load`
callback (`enif_open_resource_type`, dtor `NULL` — the buffer is inline, ERTS frees it on GC). The atoms
`ok`, `error`, `nil`, `memory_out_of_bounds`, `true`, `false` are cached in `priv_data` at `load` (so the
hot path makes no `enif_make_atom`).

**`nif_fresh(MinBytes, ReserveBytes)`** — `enif_alloc_resource(MEM_RES_TYPE, sizeof(twocore_mem) +
ReserveBytes)`; set `byte_len = MinBytes`, `max_bytes = ReserveBytes`; `memset(data, 0, ReserveBytes)` (the
whole reservation is zero, so newly-`grow`n pages read zero for free — §3.5); `term = enif_make_resource`;
`enif_release_resource` (GC now owns it); return `term`. The Gleam head computes the two byte counts from
the reservation policy (§3.5) — the C is purely mechanical and cannot over-commit beyond what it is handed.

**The bounds check (the trust boundary — overflow-safe for memory64, MF2).** The Gleam head has already
computed `ea = addr + offset` as a no-wrap BEAM bignum (MF1) and passes the **combined `Ea`**, so the C
never re-adds and cannot wrap on the addition. Because **memory64 is live** (and in the `cell_nif` corpus),
`ea` may be a full `i64`, so the check must not itself overflow. Decode `Ea` (and every `value` / `count`
operand) with **`enif_get_uint64`, never `enif_get_int`**; a **failed decode** (`Ea >= 2^64`, out of the
`ErlNifUInt64` range) is itself OOB. Then bounds-check with **guarded subtractions that cannot overflow**
(`byte_len <= 4096 * 65536 << 2^32`, so `byte_len - ea` is safe once `ea <= byte_len`):

```c
ErlNifUInt64 ea, n;
if (!enif_get_uint64(env, argv[K], &ea)) return err_oob;   /* Ea >= 2^64 -> OOB, never truncate */
if (ea > m->byte_len)      return err_oob;                  /* guarded: no add, cannot wrap */
if (n  > m->byte_len - ea) return err_oob;                  /* guarded: byte_len - ea >= 0 here */
```

This is `in_bounds` `:1473-1475` made overflow-safe: **never** the wrap-prone `(uint64)addr+(uint64)offset`
or `ea + n` form (which memory64 `i64` addresses overflow-wrap → pass the check → an OOB `memcpy`, a real
host escape the i32-only fuzz cannot catch); **never** masked mod 2^32; checked against `byte_len`,
**never** `max_bytes`. A bug here — a signed truncation via `enif_get_int`, checking `max_bytes`, an
off-by-one, or a wrapping add — is a genuine host escape; S15-04's fuzz (incl. the memory64 boundary
vectors, MF2) proves it fires and no access lands outside `[0, byte_len)`.

**`nif_load(Res, Bytes, Signed, ResultWidth, Ea)`** — decode `Ea` with `enif_get_uint64` (MF2);
bounds-check; assemble the value **explicitly little-endian** (`for k in 0..Bytes: v |=
(ErlNifUInt64)data[ea+k] << (8*k)` — LE assembled by hand, so the result is identical on any host
endianness, matching `decode_unsigned` `:1487`). If `Signed` (the `true` atom, tested via the cached atom):
sign-extend from `Bytes*8` to `ResultWidth` and return the unsigned two's-complement pattern in
`[0, 2^ResultWidth)` (`decode_signed` `:1498-1505`); else zero-extend. f32/f64 are **raw IEEE-bit moves** —
no BEAM double round-trip; the raw 4/8-byte LE pattern is returned as the integer directly. Return
`{ok, enif_make_uint64(v)}`.

**`nif_store(Res, Bytes, Ea, Value)`** — decode `Ea` and `Value` with `enif_get_uint64` (MF2); bounds-check
**first** (trap-before-write / all-or-nothing); then write the low `Bytes` bytes of `Value` little-endian
(`for k: data[ea+k] = (Value >> (8*k)) & 0xFF` — `encode_le` `:1480`, low-bits `storeN` semantics). Because
the check precedes every byte written, an OOB store mutates nothing (`mem_store` `:810-825`). Return
`{ok, nil}` / `{error, memory_out_of_bounds}`.

**`nif_size(Res)`** = `m->byte_len / 65536`. **`nif_grow(Res, Delta)`** — `new = byte_len + Delta*65536`; if
`Delta >= 0 && new <= max_bytes` bump `byte_len = new` in place and return the **previous** page count;
else return `-1` (nothing changes). No re-zero needed (the reserved tail `[byte_len, max_bytes)` is
invariantly zero — pre-zeroed at `fresh`, and never written past `byte_len` because both checked and
guard-proven-unchecked stores stay `<= byte_len`; this tail-zero invariant is part of the security
argument). The declared-max / Safe-cap enforcement is encoded in `max_bytes` (§3.5), so `new <= max_bytes`
is bit-identical to the paged `new <= m.max` check (`mem_grow`). **No fuel charge in C** — the Gleam `grow`
wrapper keeps `rt_meter.charge(Delta * page_bytes)`.

**`nif_init_data` / `nif_fill` / `nif_copy` / `nif_init` / `nif_load_bytes` / `nif_store_bytes`** — decode
every address / `count` operand with `enif_get_uint64` (MF2), then an eager whole-range
**guarded-subtraction** bounds check (both ranges for `nif_copy` / `nif_init`), then
`memmove`/`memset`/`memcpy` over the buffer; `nif_copy` is memmove (overlap-safe, and **cross-resource when
`DstRes != SrcRes`** — `enif_get_resource` validates **both** handles before the `memmove`, lesser-c);
`nif_init` / `nif_init_data` / `nif_store_bytes` read the source `ErlNifBinary` via `enif_inspect_binary`;
`nif_load_bytes` / `nif_to_flat` return `enif_make_binary` of the sliced bytes. Fuel for
`fill`/`copy`/`init` stays Gleam-side (`rt_meter.charge(count)`).

**The unchecked bodies (S4).** `nif_load_unchecked` / `nif_store_unchecked` are `nif_load` / `nif_store`
**minus the bounds compare** — decode `Ea` (u64), then a raw LE deref / write, returning a bare `int` /
`nil` (no `{ok,_}` wrap, no error path).
Sound only because the Phase-10 loop-versioning guard has already proved the whole range in-bounds before
this arm runs (trap-preservation is absolute — never hoist-and-trap-early). On tier-N a bug here is not a
contained wrong value (as it is for paged's sparse map) but a raw OOB access, which is exactly why the tier
is Unsafe-only and the guard is load-bearing.

### 3.4 `src/twocore/runtime/rt_mem_nif.gleam` — swap every body, preserve every head, keep the paged fallback

The 37 existing public heads keep their **exact signatures** (this is the whole point of the byte-identical
seam — `emit_core`'s `seam_call(mem_module, "<op>", …)` routing is unchanged). Each body becomes a
**runtime dispatch (MF3):** *if `nif_available()` (the `.so` is loaded) → source-the-handle + call the NIF
`@external`; else → delegate to the existing `rt_mem.<op>(…)` paged reference.* **The `import
twocore/runtime/rt_mem` delegation is therefore KEPT, not dropped** — it is the fallback that preserves the
Phase-11 "runs on a bare BEAM" / `runs_anywhere` property: on a `cc`-absent host with no loaded `.so`, every
head answers via the paged delegate (byte-identical, spec-correct), so the whole suite stays green with
**no per-file gating** and `conformance_test` / `mem_oracle_differential_test` / `pipeline_tier_test`
(unowned by Phase 15) keep working unchanged. `nif_available()` is a cheap cached-atom read (a loaded NIF
returns the `true` atom; the `.erl` stub returns `false`). The load/store heads compute **`ea = addr +
offset` as a no-wrap BEAM bignum** and pass the combined `Ea` to the NIF (MF1). The `@external`
declarations bind to §3.2 (each targeting its `nif_`-prefixed export):

```gleam
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_load")
fn nif_load(res: Dynamic, bytes: Int, signed: Bool, result_width: Int, ea: Int)
  -> Result(Int, TrapReason)
@external(erlang, "twocore_rt_mem_nif_ffi", "nif_available")
fn nif_available() -> Bool   // true only when the .so loaded; the .erl stub returns false (MF3 fallback)
// … one per export in §3.2, each targeting its "nif_"-prefixed export name; every load/store passes the
//    combined `ea` (never addr + offset) …
```

Body rewrites, per family (heads unchanged; bodies shown as the shape):

- **Cell family** (`load` `:103`, `store` `:124`, `size` `:138`, `grow` `:152`, `init_data` `:165`) —
  source the handle from the pdict cell (`rt_state.mem_at(0)`), call the NIF; **no write-back** for
  mutators (in-place, stable identity). `grow` charges `rt_meter.charge(delta * page_bytes)` **only on the
  success path** (`old != -1`), exactly as `rt_mem.grow` `:266-274` — a **differential-checked invariant**
  (lesser-b): a failed `grow` (`-1`) charges **no** fuel, so nif and paged meter identically (a spurious
  charge on the failure path would diverge the metered corpus).
- **Threaded family** (`t_load` `:183`, `t_store` `:201`, `t_size` `:214`, `t_grow` `:226`, `t_init_data`
  `:235`) — project `rt_state.mem(st)`, call the NIF; mutators return `rt_state.with_mem(st, handle)`
  (the **same** handle) so `st'` is the §10 rebound record. `t_grow` keeps the grow-fuel charge on success.
- **`_at` twins + bulk** (`load_at` `:268` … `t_store_at` `:360`, `fill` `:313`, `copy` `:324`, `init`
  `:336`, and the threaded `_at`/bulk `t_*` `:432-513`) — source the handle from the mem-index slot
  (`rt_state.mem_at(mem_idx)` / `rt_state.with_mem_at`), `copy` sources two handles; `fill`/`copy`/`init`
  keep their `rt_meter.charge(count)` on success (`rt_mem.fill/copy/init` `:388-450`). Index 0 is
  byte-identical to the head.
- **SIMD byte seam** (`load_bytes` `:375`, `store_bytes` `:384`, `_at` + `t_*` `:392-451`) — same handle
  sourcing, call `nif_load_bytes`/`nif_store_bytes`. The v128-memory `.wast` files run under `cell × nif`
  against native memory (§G.1).
- **Differential hook** `to_flat(mem)` `:255` — `nif_to_flat(mem)` (the handle is passed directly by the
  test).
- **`fresh` `:65` / `fresh64` `:81`** — compute the reservation (§3.5), then `nif_fresh(min_bytes,
  reserve_bytes)`; return the resource `Dynamic`.

**The four new unchecked heads (S4 — owned here per the split).** Mirror the frozen paged/atomics
signatures (`rt_mem.load_unchecked` `:226`, `store_unchecked` `:238`, `t_load_unchecked` `:502`,
`t_store_unchecked` `:522`) so `emit_mem_load_unchecked`/`emit_mem_store_unchecked` `emit_core.gleam:1691/
1729` route to them once S15-03 whitelists the module:

```gleam
pub fn load_unchecked(bytes: Int, signed: Bool, result_width: Int, addr: Int, offset: Int) -> Int
pub fn store_unchecked(bytes: Int, addr: Int, value: Int, offset: Int) -> Nil
pub fn t_load_unchecked(st: InstanceState, bytes: Int, signed: Bool, result_width: Int, addr: Int, offset: Int) -> Int
pub fn t_store_unchecked(st: InstanceState, bytes: Int, addr: Int, value: Int, offset: Int) -> InstanceState
```

Bodies: source the handle (cell pdict / threaded record), call `nif_load_unchecked` / `nif_store_unchecked`
(§3.2); `store_unchecked` returns `Nil`, `t_store_unchecked` returns the rebound record (same handle).
`emit_core` gates `mem == 0` for unchecked, so there are **no `_at` unchecked heads** (matching
paged/atomics). S15-02 lands these heads green and dead-until-called; **S15-03** flips the whitelist +
test so they route.

### 3.5 The reservation policy (S2 — reuses the atomics caps; resolves overview open seams 2–3)

The tier **reserves** its buffer up front and moves a watermark under `grow` (never `enif_realloc` — so
outstanding resource identity is never invalidated, resolving open seam 3). The reservation is chosen
**exactly as the atomics tier does**, by reusing `rt_mem_atomics.reservation` `:140-151` (32-bit) /
`reservation64` `:168-179` (64-bit) with the shared `atomics_reserve_cap_pages` — S2 "it reuses the atomics
reservation caps." The Gleam `fresh`/`fresh64` heads compute `reserve_pages = max(min_pages,
effective_max)` pages and pass `MinBytes = min_pages * 65536`, `ReserveBytes = reserve_pages * 65536` to
`nif_fresh`; `max_bytes` therefore encodes the paged `max` (= `min(declared_max ?? cap, cap, 65536)` for
i32 via `fresh_mem`; the mem64 cap via `fresh_mem64`) so `grow`'s `<= max_bytes` is bit-identical to
paged's `<= max`.

**Admissibility is the preserved gate (S5), not this unit's.** A binding whose reservation exceeds the cap
is fail-closed **rejected at link time** by `validate_binding` (the same rule the atomics tier uses — the
skeleton's `fresh64` doc `:69-74` already states unit 09 calls `reservation64` for `nif`; the i32 path
reuses `reservation`). `validate_binding` is **untouched by design** (overview §4). So at runtime
`nif_fresh` is only ever handed an admissible `ReserveBytes` and **cannot over-commit** — a tier-N memory
that would need a 4 GiB sparse backing is simply inadmissible under tier-N (it must use paged), which is
outside the differential's admissible set.

> **Open-seam-2 note (for the fan-out/critique).** Whether the i32 admissibility gate needs to be made
> explicit in `validate_binding` for `nif` (as it already is for `atomics`, and as it already is for the
> 64-bit `nif` path) is an **upstream** decision — if it does, that edit belongs to the `validate_binding`
> owner, **not** S15-02. S15-02's contract is only: given an admissible reservation, `nif_fresh` reserves
> that many bytes and `grow` stays within it, bit-identical to paged. The differential corpus uses small
> bounded memories (`min=1, max=Some(2)` — `rt_mem_nif_test.gleam:273-280`), well within any cap.

### 3.6 What is deliberately NOT here

- **`emit_core.mem_supports_unchecked`** `:1780` (the one-line `|| mem_module == mem_module_for(Nif)`
  whitelist add) and the **`emit_unchecked_test`** flip `:77-85` — **S15-03** (the overview split). Until
  S15-03 lands, tier-N's new unchecked heads are dead code (never routed), so S15-02 lands with
  `nif_falls_back_to_the_checked_path_test` **still green** (the whitelist still excludes `nif`).
- **The bounds-check fuzz** (`rt_mem_nif_safety_test.gleam`) and the **full `cell_nif` matrix wiring**
  (`combos.gleam` → native) — **S15-04**. S15-02 lands the *per-op* differential; S15-04 lands the
  corpus-wide `cell_nif` differential + the adversarial fuzz over the C bounds-check.
- **The four Safe-forbidden gates** (`validate_binding` `SafeForbidsNif` `profiles.gleam:545`, the
  `instantiate` panic `:261-267`, type-unconstructibility, the `--link` `LinkTierNif` gate
  `twocore.gleam:598-624`) — **untouched** (S5). This unit adds capability, not posture.

---

## §4. The work (ordered, buildable)

1. **`c_src/twocore_rt_mem_nif.c`** — implement the 14 memory ops (§3.2/§3.3) against the frozen `.h`: the
   resource type + cached atoms in `load`, `fresh`, the checked load/store/size/grow/init_data +
   fill/copy/init + load_bytes/store_bytes, `to_flat`, and the two unchecked bodies — **plus the real
   `nif_available` C body returning `true`** (so the MF3 fallback probe flips to native once the `.so` is
   loaded; the `.erl` stub returns `false`). `ERL_NIF_INIT` names the frozen shim module. Prove it compiles
   under the S15-01 build FFI on both `cc`s (gcc/clang) — the `nif_ping` path already proved the toolchain;
   this adds the real `nif_funcs`.
2. **`src/twocore/runtime/rt_mem_nif.gleam`** — add the 14 `nif_`-prefixed `@external` decls (+
   `nif_available`); swap all 37 bodies to the **native-if-`nif_available()`-else-paged-delegate dispatch**
   (§3.4, MF3), keeping every fuel charge and the rebound-record semantics; add the 4 unchecked heads.
   **KEEP the `import twocore/runtime/rt_mem`** — it is the runtime fallback (MF3), not dead weight, so there
   is no unused-import warning to clear (and `fresh`/`fresh64` additionally reuse `rt_mem_atomics` for the
   reservation). `gleam build` — zero warnings.
3. **`test/twocore/runtime/rt_mem_nif_test.gleam`** — gate the existing 3-way differential (`run_differential`
   `:271`, `diff_loop` `:284`, `apply_nif` `:310`) on a successful build+`load_nif` via the S15-01 build
   FFI; skip-categorize (never a false green) when `cc` is absent (§5). Add the `cc`-absent-skips test and
   the ABI-atom round-trip test.
4. `gleam format` → `gleam build` (**zero warnings**) → `gleam test` — the differential green against the
   real NIF where `cc` is present (CI ubuntu gcc, dev macOS clang), categorized-skip otherwise.
5. **Verify default emission unaffected** — the existing corpus/conformance run is unchanged (tier-P/tier-O
   byte-identical; tier-N is opt-in). Record the unit green + `«NIF-BUILD-FROZEN»`-consumed in `state.md`.

---

## §5. Tests (`test/twocore/runtime/rt_mem_nif_test.gleam`) — the differential IS the proof (S2/S7)

Objective tests against the **WebAssembly linear-memory spec** (byte-addressed, little-endian, page =
65536 bytes; a load/store traps iff `ea + n > length`, `ea = i + offset`, no wraparound; `memory.grow`
returns previous pages or `-1`; `memory.fill/copy/init` trap conditions) — **not** change-detectors. The
tier being **bit-identical to the paged reference for every access IS the proof**; C source and emitted
term shapes are never golden'd (S7).

**The gate (S6).** Every native assertion is wrapped by a build+load attempt through the S15-01 build FFI
(`os:find_executable("cc")` → `cc -shared -fPIC` to tempdir → `erlang:load_nif`, `erl_nif.h` from the frozen
`erts_include/0` resolver — keystone §3.5, **not** the bare `code:lib_dir(erts, include)`), which is
**node-global and idempotent**. Present ⇒ run against the real NIF. Absent ⇒ **categorized skip** (the
differential is not run; the assertion is recorded as skipped, not passed). This mirrors the Elixir binding
arm's `elixirc` skip-gate (`twocore_bindings_ffi.erl`).

1. **Per-op `nif ≡ paged ≡ oracle` differential (the load-bearing proof).** The existing
   `run_differential`/`diff_loop` (`:271-307`) drives the tier-N handle, the paged handle, and the
   flat-binary oracle through the SAME randomized `count` ops (load/store/grow/init at random + boundary
   addresses/counts/widths, signed and unsigned, widths 1/2/4/8, `result_width` 32/64) and asserts, **at
   every step**: identical value **and** identical trap (`rn == rp`, `rn == ro`), **and** an identical
   whole in-bounds byte image via the frozen `to_flat` hook (`nif.to_flat(mem) == rt_mem.to_flat(mem) ==
   rt_mem.o_flat(o)`). Now runs against the **real NIF** (gated). This is the strongest byte-for-byte
   check and is the exact test that catches a C endianness / sign-extension / bounds bug before it escapes.
   Cover the Cell **and** Threaded families and, additionally, `_at` (index 0 ≡ head, plus a two-memory
   `copy`), the bulk ops, and the SIMD `load_bytes`/`store_bytes` seam.
2. **Spec-cited edge vectors (differential, not goldens).** Assert against the spec directly, comparing
   nif to the oracle: `i32.load8_s` of byte `0x80` → `0xFFFFFF80`; `i64.load8_s` of `0x80` →
   `0xFFFFFFFFFFFFFF80` (sign-extension to `result_width`, `decode_signed` `:1498`); a load at
   `ea = byte_len - n` succeeds and at `ea = byte_len - n + 1` traps `MemoryOutOfBounds` (the exact bound);
   `addr = 0xFFFFFFFF` + a large `offset` traps (no wrap — `ea` never masked); a multi-byte store that
   would straddle the end leaves the buffer **unchanged** (trap-before-write — compare `to_flat` before/
   after); `grow` returns previous pages, exposes zero-filled pages, and returns `-1` (nothing allocated)
   past `max_bytes`.
3. **`cc`-absent path is explicitly tested to skip (never a false green, S6).** A test that forces the
   toolchain-absent branch (or asserts the gate's `{error, _}` return) categorizes a **skip**, and — where
   the NIF is genuinely unavailable — the native differential does not run and is not counted as passed.
4. **Default output unaffected.** tier-P/tier-O emission is byte-identical and `MemTier`/`mem_module_for`/
   `validate_binding` are untouched (asserted by the unchanged corpus/conformance run — DoD §6.5); the
   Safe-forbidden unconstructibility (`safe_forbids_nif_is_unconstructible_test` `:668-677`) stays green.
5. **ABI atom round-trip (guards the frozen term shapes).** Assert that the NIF's `{error,
   memory_out_of_bounds}` decodes to the Gleam `Error(MemoryOutOfBounds)` and `{ok, nil}` to `Ok(Nil)` —
   a direct `should.equal(nif.store(oob…), Error(MemoryOutOfBounds))` — so an atom drift between the C and
   the Gleam-compiled constructor is caught here, not mis-decoded silently. (Gated; the fallback-vs-native
   distinction is irrelevant — the term shape must match either way.)

> The **adversarial C-bounds-check fuzz** (random/edge addresses + counts at and past the boundary and at
> `grow` watermarks, proving the trap fires and nothing lands outside `[0, byte_len)`) is **S15-04's**
> (`rt_mem_nif_safety_test.gleam`), as is the corpus-wide `cell_nif` differential. S15-02 lands the per-op
> differential; S15-04 lands the security fuzz + the full matrix.

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. Spec-cited differential tests (§5) green against the **real NIF** where `cc` is present (CI ubuntu gcc,
   dev macOS clang), and **categorized-skip** where absent (the `cc`-absent path itself tested to skip —
   never a false green, S6). The per-op `nif ≡ paged ≡ oracle` value/trap/byte-image equality (§5 test 1)
   holds for the Cell and Threaded families, the `_at` twins, the bulk ops, and the SIMD seam.
2. `///` contract docs on **every** head kept/added: the 37 preserved heads' docs updated from "NOT the
   native ceiling / delegates to `rt_mem`" to the real native contract (bounds-check in C, in-place
   mutation, stable handle, fuel charged Gleam-side), and full `///` contracts on the 4 new unchecked heads
   (bottom-line: no bounds compare, sound only under the Phase-10 guard, Unsafe-only). The `.c` carries
   file + per-export comments (the ABI, the bounds-check-is-the-boundary note on every checked op).
3. `gleam format --check src test` clean.
4. `gleam build` **zero warnings** (the `rt_mem` delegation import dropped where unused; no unused var).
5. The unit suite passes **or categorizes the skip when no `cc`**; **default emission unaffected** — the
   existing corpus/conformance suite is green and unchanged (tier-P/tier-O byte-identical; `OptNone ≡
   Baseline ≡ Aggressive` and `Safe ≡ Unsafe` undisturbed; the exact running total re-confirmed).
6. `state.md` records S15-02 green, `«NIF-BUILD-FROZEN»` consumed, and the two downstream handoffs (§7)
   — S15-03's whitelist/test-flip and S15-04's fuzz/matrix — noted as pending.

---

## §7. What it leaves (handoff to downstream)

- **S15-03 (unchecked wiring):** binds to the 4 unchecked heads this unit lands. It adds the **one-line**
  `|| mem_module == profiles.mem_module_for(Nif)` to `emit_core.mem_supports_unchecked` `:1780` and **flips**
  `emit_unchecked_test.nif_falls_back_to_the_checked_path_test` `:77-85` from "nif falls back to checked" to
  "nif emits unchecked." No `rt_mem_nif.gleam` / `.c` edit — the heads + bodies are already here (the
  overview split keeps those two files single-owner). Correctness preserved: the Phase-10 loop-versioning
  guard proves the range in-bounds before the unchecked arm runs.
- **S15-04 (node-safety + full matrix):** binds to the checked ops + `to_flat`. It adds the **adversarial
  C-bounds-check fuzz** (`rt_mem_nif_safety_test.gleam` — random/edge addresses + counts at/past the
  boundary and at `grow` watermarks, plus the **memory64 boundary vectors** MF2 requires, proving the trap
  fires in C and no access escapes `[0, byte_len)`) and wires `combos.gleam`'s `cell_nif` (`:117`) so the
  corpus-wide `(mode × state_strategy × mem_tier × table_tier)` differential
  (`tier_differential_test.whole_corpus_tier_differential_test`) exercises **native** memory when the `.so`
  is loaded. Because this unit KEEPS the paged-delegate fallback (MF3), a `cc`-absent node **automatically**
  answers `cell_nif` via the delegate — byte-identical, no per-file gating, nothing regresses; the
  native-specific proof is the categorized skip in `rt_mem_nif_safety_test`. Phase-11 L1 keeps excluding
  `nif` from the `--link` matrix (`linked_selfcontained_test.gleam:334-335`, O8).
- **S15-05 (capstone):** measures the **real nif column** in `docs/phase-4-benchmark.md` against the ops
  this unit lands, states the honest ceiling (the NIF removes paged rebuild cost and — via S15-03's
  unchecked — the bounds-check cost, but the per-access inter-module seam-call floor remains — no hero
  number), documents the deployment `priv/*.so` packaging follow-on, regenerates `docs/wasm-conformance.svg`,
  and compacts the phase into `../01-status.md`.
- **Open seams surfaced for the fan-out/critique:** the exact i32 reservation-cap admissibility gate in
  `validate_binding` (open seam 2, §3.5 — upstream, not S15-02) and the macOS-clang vs Linux-gcc `cc` flag
  portability (open seam 4 — proven by the S15-01 `nif_ping` before this unit depends on it, e.g.
  `-undefined dynamic_lookup` on macOS vs `-shared` on Linux).
