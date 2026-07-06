# S15-01 — The keystone: freeze the native NIF toolchain path (the pipe, not the water)

> **Status:** scoped, awaiting build. **Owner:** S15-01 (the keystone — goes first and alone,
> Wave 0). **Freeze:** produces `«NIF-BUILD-FROZEN»`. **Read order:** [`00-overview.md`](00-overview.md)
> (decisions S1–S8, the DAG, the D1 file-ownership map — AUTHORITATIVE) → the distilled codebase map
> (`brief-phase15-cnif.md`, exact `file:line` edit points) → this doc. All prior-phase decisions and the
> permanent invariants ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold.
>
> This unit lands **green with `rt_mem_nif.gleam` still the byte-identical paged-delegate — untouched**.
> It ships *no memory logic*: a `c_src/twocore_rt_mem_nif.h` (the reserved-buffer resource struct + the
> per-op ABI contract), a `src/twocore_rt_mem_nif_ffi.erl` NIF shim (`-on_load` bootstrap + one
> `nif_error(nif_not_loaded)` stub per exported NIF), a `test/twocore_rt_mem_nif_build_ffi.erl`
> toolchain-gated compile-to-tempdir + `load_nif` harness, and a `test/twocore/runtime/rt_mem_nif_build_test.gleam`
> that proves the whole path with a **trivial `nif_ping` NIF that compiles + loads + returns `pong`** on CI
> gcc *and* macOS clang, skip-categorized where no `cc` is present. **No default emission changes; no tier
> behaviour changes.** The keystone proves the *pipe*, not the water.

**Honors:** **S1** (this *is* the keystone — freeze the native toolchain path end-to-end *before* any
memory logic) and **S6** (the test-time build gates on a C toolchain, categorizing the skip on absence,
never a false green). It **freezes the ABI that S2/S3/S4 fill** (the resource struct, the shim export
table incl. the still-stubbed unchecked heads, the `.so`/`load_nif` path convention, and the build-gate
signature) **without implementing any of it**. It **preserves S5** (touches none of the four
Safe-forbidden gates and does not go near `emit_core`), **S7** (the proof is compile+load, not a golden —
no test locks C source or emitted Core text), and **S8** (scope: the five owned files only).

---

## §1. Goal

The load-bearing risk of Phase 15 is **not** the memory algebra — the paged reference
(`twocore/runtime/rt_mem`) already defines it bit-exact, and the tier-N skeleton
(`rt_mem_nif.gleam`) already delegates to it. The risk is **getting a C `erl_nif` NIF to compile and load
across CI (gcc) and dev (clang) under the repo's no-native-build reality**: there is *no* `c_src/`,
`priv/`, `Makefile`, `rebar.config`, or `*.c/.h/.so` anywhere, `gleam.toml` has no native config, and
`gleam build` compiles `src/*.erl` but **not** `c_src/*.c` (Gleam has no native pre-build hook) — so the
`.so` is out of band (brief §"THE C-BUILD / TEST / CI STORY", lines 44–50).

So the keystone freezes the **whole toolchain seam** every downstream unit binds to, and proves it live:

- **`c_src/twocore_rt_mem_nif.h`** — the `enif_alloc`'d **reserved-buffer** resource struct
  (`byte_len` watermark + `max_bytes` reservation cap + flexible `data[]`), the resource-type name, and
  the per-operation Erlang-visible ABI contract (names / arities / argument order / return shapes) that
  the C core (S15-02) and the Gleam heads (S15-02) both bind to.
- **`src/twocore_rt_mem_nif_ffi.erl`** — the NIF shim: `-on_load` → `erlang:load_nif`, and one
  `erlang:nif_error(nif_not_loaded)` stub per exported NIF, with the **exact** export names/arities the
  Gleam `@external`s will call (structurally mirroring the `twocore_rt_mem_atomics_ffi.erl` precedent, but
  NIF-backed instead of pure-Erlang).
- **`test/twocore_rt_mem_nif_build_ffi.erl`** — the `os:find_executable("cc")` (fallback `"gcc"`) gate + a
  `run_port` `cc -shared -fPIC` compile-to-tempdir + `erlang:load_nif`, **skip-categorized on absence**
  (modelled verbatim on `test/twocore_bindings_ffi.erl:52-56` and `:277-292`).
- **`test/twocore/runtime/rt_mem_nif_build_test.gleam`** — the `nif_ping` proof: `compile + load_nif +
  call → 'pong'` on both platforms; plus the gate-categorization assertion for the no-`cc` host.
- **`.gitignore`** — the tempdir/priv `.so`/`.dylib`/`.o` build artifacts (open seam #5, resolved: yes).

**Acceptance for this unit:** on a host with `cc`/`gcc`, `nif_ping` compiles into a loadable `.so`,
`load_nif` attaches it to the shim, and `twocore_rt_mem_nif_ffi:nif_ping()` returns the atom `pong`; on a
host without a C toolchain, the tier-N build test prints a **categorized skip** and passes; and the whole
suite (including the existing `rt_mem_nif_test.gleam` paged-delegate differential) stays green with
`rt_mem_nif.gleam` byte-identical.

---

## §2. Depends on / Produces

**Depends on (read-only, frozen upstream):**

- `test/twocore_bindings_ffi.erl` — the **template** for the test-time-compile pattern (the Phase-12
  binding harness). Copy its shape, not its body: `which/1` = `os:find_executable/1 →
  {ok,Path}|{error,nil}` (the gate, `:52-56`); `run_port/3` = `open_port({spawn_executable,Exe},
  [{args,Args},{cd,Cwd},exit_status,stderr_to_stdout,binary,hide])` with a bounded collect loop
  (`:277-292`); `fresh_dir/1` = a per-call unique dir under `$TMPDIR` (`:299-304`); the toolchain-absent
  arm returns an error that the caller **categorizes as a skip** (`compile_load_gleam/2:114-118`,
  `compile_load_elixir/2:157-161`).
- `test/twocore/backend/emit_elixir_bindings_test.gleam:308-316` — the **skip-categorization idiom**:
  `case which(tool) { Error(_) -> io.println("… SKIPPED (categorized …)") Nil ; Ok(_) -> run() }` — a
  pass, never a failure, never a false green.
- `src/twocore_rt_mem_atomics_ffi.erl` + `rt_mem_atomics.gleam:102-111` — the **hand-written `src/` FFI
  precedent** (tier-O `atomics` is pure Erlang, *not* a NIF: no `load_nif`, no `priv`, no `.so`). tier-N
  is the **first real NIF**; the shim is structurally identical (`twocore_`-prefixed Erlang under `src/`,
  `@external(erlang, "twocore_rt_mem_nif_ffi", "<fn>")`) but its exported bodies are `load_nif`-replaced
  stubs, not thin BIF wrappers.
- `src/twocore/runtime/rt_mem_nif.gleam` — the **paged-delegate skeleton**, read-only this unit. Its
  frozen heads (`fresh :65`, `fresh64 :81`, `load :103`, `store :124`, `size :138`, `grow :152`,
  `init_data :165`, the `t_*` threaded twins `:183-241`, the `_at` twins `:268-309`, bulk `fill/copy/init
  :313-344`, SIMD `load_bytes/store_bytes :375-410`, `to_flat :255`) are the surface S15-02 will re-body
  onto the frozen shim. The keystone does **not** touch it.
- `.github/workflows/test.yml` — CI is `ubuntu-latest` (ships `gcc`/`cc`), erlef/setup-beam OTP 29 +
  Gleam 1.17.0, runs `gleam test` then `gleam format --check src test` (`:66-67`). Elixir is commented out
  (`:20`) — which is exactly why the Elixir binding arm skip-gates; the tier-N NIF **genuinely builds on
  CI** (gcc present) and skip-categorizes only on a toolchain-less host.

**Produces `«NIF-BUILD-FROZEN»`** — the four frozen surfaces downstream binds to:

1. **The resource ABI** — the `twocore_mem_t` reserved-buffer struct (§3.1) and the resource-type name.
2. **The shim export table** — every NIF name/arity (§3.3), including the still-stubbed
   `nif_load_unchecked`/`nif_store_unchecked` heads (so S15-02/03 add C + Gleam without ever editing the
   shim).
3. **The `.so` name / `ERL_NIF_INIT` module / `-on_load` path convention** — `.so` basename
   `twocore_rt_mem_nif`, `ERL_NIF_INIT` module atom `twocore_rt_mem_nif_ffi`, `-on_load` resolves the
   `.so` via the `TWOCORE_RT_MEM_NIF_SO` env override then `priv/` (§3.2, §3.5).
4. **The build-gate signature** — `test/twocore_rt_mem_nif_build_ffi.erl`'s `which/1`, `cc/0`,
   `compile_load_probe/0`, `compile_load_cnif/0` (§3.4) — the entry points S15-02/03/04 call to compile
   the **real** `c_src/twocore_rt_mem_nif.c` at test time.

**Unblocks** S15-02 (native backend — the C core + the `@external` rewrite + the per-op `nif ≡ paged ≡
oracle` differential), S15-03 (unchecked whitelist + `emit_unchecked` test flip), S15-04 (bounds-check
fuzz + full `cell_nif` matrix), and S15-05 (capstone benchmark). None of them re-derive the toolchain
seam — they all call the frozen build gate.

---

## §3. What it owns + design

**Owned files (D1) — this unit is the sole owner of each; `rt_mem_nif.gleam` stays the untouched
paged-delegate:**
new `c_src/twocore_rt_mem_nif.h` · new `src/twocore_rt_mem_nif_ffi.erl` · new
`test/twocore_rt_mem_nif_build_ffi.erl` · new `test/twocore/runtime/rt_mem_nif_build_test.gleam` ·
`.gitignore`.

> **D1 note (overview §4 + open-seam #1).** The overview's recommended split is honored here: **S15-02**
> owns *all* of `c_src/twocore_rt_mem_nif.c` **and** `src/twocore/runtime/rt_mem_nif.gleam` (checked +
> unchecked bodies/heads); **S15-03** owns *only* the one-line `emit_core` `mem_supports_unchecked`
> whitelist entry + the `emit_unchecked_test` flip. This keystone therefore does **not** create the `.c`
> (it embeds a throwaway `nif_ping` probe source *inside the build FFI* — never a committed `c_src/*.c` —
> so `c_src/twocore_rt_mem_nif.c` stays S15-02's alone), and it declares the unchecked NIF names in the
> shim table (stubs) so S15-02/03 add code without ever touching the shim.

### 3.1 `c_src/twocore_rt_mem_nif.h` — the reserved-buffer resource struct + the ABI contract

The frozen resource layout (S2's `struct { size_t byte_len, max_bytes; unsigned char data[]; }`, made
concrete). The keystone **defines** it; S15-02's `.c` **fills** the ops over it:

```c
/* The tier-N linear-memory resource: a single enif_alloc_resource'd block whose flexible
 * data[] array IS the raw WASM linear memory. RESERVATION model (open seams #2/#3, resolved):
 * the buffer is sized to max_bytes ONCE at nif_fresh and NEVER realloc'd — grow only bumps the
 * byte_len watermark inside [0, max_bytes], so outstanding resource identity / pointers are never
 * invalidated (enif_realloc_resource is deliberately NOT used). */
typedef struct {
    size_t byte_len;        /* logical size in bytes (= pages * 65536); the grow watermark. */
    size_t max_bytes;       /* reserved capacity ceiling; grow FAILS (-1) past this. */
    unsigned char data[];   /* the raw byte buffer; data[0..byte_len) is live, [byte_len..max_bytes) reserved-zero. */
} twocore_mem_t;

/* enif_open_resource_type name (frozen; S15-02 opens it in the load callback). */
#define TWOCORE_RT_MEM_NIF_RESOURCE "twocore_rt_mem_nif_resource"
```

**Frozen invariants the `.h` documents (S2/S3, the C core must honor verbatim):**
- **LITTLE-endian** byte moves; f32/f64 are **raw IEEE-bit** moves (never a BEAM `double` round-trip).
- Sub-word **signed** loads sign-extend to `result_width` and return the unsigned two's-complement bit
  pattern in `[0, 2^result_width)`; else zero-extend (mirrors `rt_mem` `:1498-1505`).
- The effective address `ea = addr + offset` is a **no-wrap** value; the trap condition is exactly
  `ea < 0 || ea + n > byte_len → MemoryOutOfBounds` (the **security boundary** — bounds-checked **in C**,
  wrap-safe, *before* any byte is touched; multi-byte stores / `fill` / `copy` / `init` are
  **trap-before-write / all-or-nothing**). *A bug here is a genuine host escape* — S15-04 fuzzes it.
- `grow` bumps `byte_len` within the reserved `max_bytes`, zero-filling the new region, returning the
  previous page count or `-1` (reservation caps reused from the atomics tier — `rt_mem_atomics`
  reservation gates, brief line 50; S15-02 wires the exact sizing, an open-seam it confirms *within* this
  frozen struct).

> The op *bodies* are `static` C registered via `nif_funcs[]`, so the `.h` needs no per-op C prototype —
> the authoritative per-op contract is the Erlang-visible ABI table (§3.3), which the `.h` restates as a
> documentation block so the C author and the Gleam author read one frozen surface.

### 3.2 `src/twocore_rt_mem_nif_ffi.erl` — the NIF shim (`-on_load` + stubs)

A `twocore_`-prefixed hand-written Erlang module under `src/` (namespace convention: overview §5, same as
`twocore_rt_mem_atomics_ffi`). Two frozen conventions:

**(a) `ERL_NIF_INIT` module atom = the shim module = `twocore_rt_mem_nif_ffi`.** `load_nif` attaches NIFs
to the module *in whose code it runs*, and `ERL_NIF_INIT`'s first token **must** name that same module.
The Gleam `@external`s target `"twocore_rt_mem_nif_ffi"` (the atomics precedent), so S15-02's `.c` must
declare `ERL_NIF_INIT(twocore_rt_mem_nif_ffi, …)` — **not** `twocore_rt_mem_nif` (the brief line 50's
`ERL_NIF_INIT(twocore_rt_mem_nif, …)` is shorthand; the frozen, load-verified module atom is the
`_ffi`-suffixed shim). *Confirmed live* (§3.5): with `ERL_NIF_INIT(twocore_rt_mem_nif_ffi, …)`, `load_nif`
attaches and `nif_ping()` dispatches to C.

**(b) `-on_load` resolves the `.so` via env-override → `priv/`, calls `load_nif`, returns `ok` (soft).**

```erlang
-module(twocore_rt_mem_nif_ffi).
-on_load(init/0).
init() ->
    Base = case os:getenv("TWOCORE_RT_MEM_NIF_SO") of   %% test-time override (build FFI sets it)
               false -> filename:join(code:priv_dir(twocore), "twocore_rt_mem_nif");  %% deployment (follow-on)
               P     -> P
           end,
    _ = erlang:load_nif(Base, 0),   %% SOFT: return ok regardless — see below
    ok.
```

- `load_nif`'s path arg is the `.so` basename **without** the `.so` extension; the file on disk is
  `twocore_rt_mem_nif.so`. Frozen `.so` basename: **`twocore_rt_mem_nif`**.
- **Soft return (frozen decision):** `init/0` returns `ok` *even when `load_nif` fails* — so the shim
  always loads and its stubs stay callable, raising the honest `nif_error(nif_not_loaded)` (the
  categorized "not loaded" signal) rather than making the module unloadable (`undef`). The paged-delegate
  (`rt_mem_nif.gleam`, untouched this unit) never calls the shim, so at keystone time the shim is inert
  unless the build test force-loads it. This is why an absent `.so` cannot perturb the default suite.
- **Env override is the test-time load path:** the build FFI (§3.4) sets `TWOCORE_RT_MEM_NIF_SO` to the
  freshly-compiled tempdir base, then force-reloads the shim (`code:purge` + `code:load_file` re-runs
  `-on_load`) so `load_nif` attaches the just-built `.so`. `priv/twocore_rt_mem_nif` is the *deployment*
  path (prebuilt per-platform `.so`) — a **documented follow-on**, not built this phase.

**The stub export table** — one `erlang:nif_error(nif_not_loaded)` body per exported NIF, with the exact
names/arities the Gleam `@external`s bind to (§3.3), **except `nif_available/0`, whose Erlang stub returns
the atom `false`** (not `nif_error`) so the runtime paged-delegate fallback probe (MF3) answers honestly
when no `.so` is loaded. At keystone only `nif_ping/0` (and, once S15-02 lands, the real `nif_available/0`
returning `true`) gets a real C body; the rest stay `nif_not_loaded` stubs until S15-02's `.c` lands (and
are then attached by the same `load_nif`).

### 3.3 The frozen NIF export table (the ABI seam)

The resource is the sole state, so the family/threading/fuel/`Result`/`Option` glue lives in S15-02's
**Gleam heads** (each frozen `rt_mem_nif.gleam` head — cell/threaded, plain/`_at`, `fresh64` — wraps
these NIFs; e.g. threaded `t_store` extracts the resource from `st`, calls `nif_store`, rebinds; `fresh64`
computes `ByteLen`/`MaxBytes` in Gleam then calls `nif_fresh`; the trap wrap `{error,oob} →
Error(MemoryOutOfBounds)` is Gleam-side, since the tier module never calls `rt_trap`). The NIFs therefore
collapse onto this **resource-primitive** ABI — frozen here, filled by S15-02:

| NIF (name/arity) | Args | Returns | Notes |
|---|---|---|---|
| `nif_ping/0` | — | `'pong'` | **keystone probe only** (the real C body lands this unit). |
| `nif_available/0` | — | `bool` | `true` **only when the `.so` is loaded** (real C body); the Erlang stub returns `false` — the runtime **paged-delegate fallback** probe the Gleam heads dispatch on (MF3). |
| `nif_fresh/2` | `ByteLen, MaxBytes` | `Resource` | `enif_alloc_resource(sizeof + MaxBytes)`; zero-fill `[0,ByteLen)`. |
| `nif_size/1` | `Resource` | `Pages :: int` | `byte_len / 65536`. |
| `nif_grow/2` | `Resource, DeltaPages` | `PrevPages :: int \| -1` | bump watermark in `max_bytes`, zero-fill new region. |
| `nif_load/5` | `Resource, Bytes, Signed, ResultWidth, Ea` | `{ok, int} \| {error, memory_out_of_bounds}` | LE, sign/zero-extend per `Signed`. |
| `nif_store/4` | `Resource, Bytes, Ea, Value` | `ok \| {error, memory_out_of_bounds}` | trap-before-write. |
| `nif_init_data/3` | `Resource, Ea, Data :: binary` | `ok \| {error, memory_out_of_bounds}` | active data init. |
| `nif_load_bytes/3` | `Resource, Ea, N` | `{ok, binary} \| {error, memory_out_of_bounds}` | SIMD byte seam. |
| `nif_store_bytes/3` | `Resource, Ea, Data :: binary` | `ok \| {error, memory_out_of_bounds}` | SIMD byte seam. |
| `nif_fill/4` | `Resource, Dest, Value, Count` | `ok \| {error, memory_out_of_bounds}` | all-or-nothing. |
| `nif_copy/5` | `DstRes, SrcRes, Dst, Src, Count` | `ok \| {error, memory_out_of_bounds}` | `_at` twins select the resource in Gleam. |
| `nif_init/5` | `Resource, Seg :: binary, Dst, Src, Count` | `ok \| {error, memory_out_of_bounds}` | Gleam supplies the segment bytes. |
| `nif_to_flat/1` | `Resource` | `binary` | whole in-bounds image (differential hook, tests only). |
| `nif_load_unchecked/5` | `Resource, Bytes, Signed, ResultWidth, Ea` | `int` | **stub now**; S15-02 fills (no bounds compare). |
| `nif_store_unchecked/4` | `Resource, Bytes, Ea, Value` | `ok` | **stub now**; S15-02 fills (raw deref). |

14 memory ops + `nif_ping` + `nif_available` = **16 frozen exports**. The `_at` multi-memory twins and the
`t_*` threaded twins need **no** separate NIFs (Gleam picks the resource / rebinds); `fresh64` reuses
`nif_fresh`. OOB is signalled `{error, memory_out_of_bounds}` and mapped to `Error(MemoryOutOfBounds)` in
the Gleam head.

**The `nif_` name prefix is deliberate (MF5).** Every export is `nif_`-prefixed so no name collides with a
BEAM auto-imported BIF — `nif_size`/`nif_init`/`nif_copy`/`nif_fill` cannot clash with the autoimported
`size/1`/`init`/`copy`/etc. the way bare names would. (The `atomics` precedent is bare-safe only by luck;
the NIF surface is wide enough that the prefix is load-bearing.) The Gleam `@external` target strings, the
`.erl` stub export names/arities, and the C `ERL_NIF_INIT` `nif_funcs` all use **these exact names
verbatim** — S15-02's §3.2 table restates this same list, it does not re-spell it.

**The effective address is combined Gleam-side (MF1/MF2).** Every load/store/unchecked NIF takes a **single
`Ea` operand**, not a split `addr, offset`. The Gleam head computes `ea = addr + offset` as a **BEAM bignum
(no wrap)** and passes the combined `Ea`; the C **never re-adds** `addr + offset`, so it cannot wrap on the
addition. The C decodes `Ea` with `enif_get_uint64` (a failed decode — `Ea >= 2^64` — is itself OOB) and
bounds-checks with guarded subtractions (S15-02 §3.3, MF2). This is the frozen argument shape both the
`.erl` stubs and the Gleam `@external`s bind to.

> **Freeze-amendment protocol (mirrors the reference's "raise a disagreement before building").** The
> combined-`Ea` argument shape is **frozen** (MF1): the Gleam head computes `ea = addr + offset` as a
> no-wrap bignum and the C bounds-checks the combined `Ea` with guarded subtractions (S15-02 §3.3), so **no
> `addr,offset` split is needed even for the memory64 boundary** (MF2 handles it in-C via `enif_get_uint64`
> + guarded subtraction). If the S15-02 fan-out nonetheless finds the resource-primitive granularity
> mis-sized, that is a freeze **amendment** to raise with the planner *before* S15-02 builds — not a silent
> divergence. The struct + `.so`/`load_nif` convention + build-gate signature are stable regardless.

### 3.4 `test/twocore_rt_mem_nif_build_ffi.erl` — the toolchain-gated build harness

A `test/`-side `twocore_`-prefixed Erlang FFI (test-only trust boundary, exactly like
`twocore_bindings_ffi.erl`). **Frozen exports (the build-gate signature downstream calls):**

| Export | Returns | Purpose |
|---|---|---|
| `which/1(Exe :: binary)` | `{ok, binary} \| {error, nil}` | `os:find_executable` probe (the gate; `bindings_ffi:52-56`). |
| `cc/0` | `{ok, binary} \| {error, nil}` | resolve `"cc"` then fallback `"gcc"`. |
| `compile_load_probe/0` | `loaded \| skip_no_toolchain \| {build_error, binary}` | **keystone**: compile the embedded `nif_ping` probe `.c` + load. |
| `compile_load_cnif/0` | `loaded \| skip_no_toolchain \| {build_error, binary}` | **downstream**: compile the committed `c_src/twocore_rt_mem_nif.c` + load. |

The three-value return marshals directly onto a Gleam custom type (`loaded → Loaded`,
`skip_no_toolchain → SkipNoToolchain`, `{build_error, Bin} → BuildError(String)`), so the Gleam caller
pattern-matches with no manual decode.

**Internal machinery (shared by both `compile_load_*`):**
1. **Gate** — `cc/0`; `{error, nil}` (neither `cc` nor `gcc`) ⇒ return `skip_no_toolchain` **before any
   compile** (the categorized skip; never a false green — S6).
2. **erl_nif.h include dir** — `erts_include/0`, a **robust** resolver (see §3.5; the brief's bare
   `code:lib_dir(erts, include)` is *not* reliable — proven broken on this host).
3. **Stage** — `fresh_dir("twocore_rt_mem_nif_build")` under `$TMPDIR` (`bindings_ffi:299-304`); write the
   `.c` (embedded `nif_ping` probe for `compile_load_probe`, or the committed `c_src/twocore_rt_mem_nif.c`
   for `compile_load_cnif`) plus the committed `c_src/twocore_rt_mem_nif.h` into the dir.
4. **Compile** — `run_port(Cc, CFlags, Dir)` (the exact port pattern `bindings_ffi:277-292`) where
   `CFlags` = the `os:type()`-selected flag vector (§3.5). Non-zero exit ⇒ `{build_error, <stdout/stderr>}`.
5. **Load + probe** — `os:putenv("TWOCORE_RT_MEM_NIF_SO", <Dir>/twocore_rt_mem_nif)`, then `code:purge` +
   `code:delete` + `code:load_file(twocore_rt_mem_nif_ffi)` to re-run `-on_load` against the just-built
   `.so`; then verify by calling `twocore_rt_mem_nif_ffi:nif_ping()` inside a `try` — `pong ⇒ loaded`; a
   raised `nif_not_loaded` (soft `-on_load` swallowed a `load_nif` failure) ⇒ `{build_error,
   load_nif_failed}` (a **loud** failure — a broken pipe is a bug, never a skip).
6. **Cleanup** — `file:del_dir_r(Dir)`.

> The embedded `nif_ping` probe `.c` lives as a binary string constant *inside this FFI* (never a
> committed `c_src/*.c`, keeping `c_src/twocore_rt_mem_nif.c` S15-02's). It `#include "twocore_rt_mem_nif.h"`,
> opens the resource type in its `load` callback (`enif_open_resource_type(env, NULL,
> TWOCORE_RT_MEM_NIF_RESOURCE, NULL, ERL_NIF_RT_CREATE, NULL)`) and defines `nif_ping → enif_make_atom(env,
> "pong")`. One compile therefore proves the *entire* toolchain path in one shot: `erl_nif.h` resolution,
> the committed `.h` compiling, resource-type registration, `ERL_NIF_INIT` dispatch, and term marshalling
> back to Erlang.

### 3.5 The cross-platform `cc` invocation (EMPIRICALLY CONFIRMED)

The keystone's central claim was proven **live on this dev host** (macOS clang, arm64, Erlang/OTP 29,
erts 17.0.2): a `nif_ping` `.c` compiled with the flags below produced a loadable `.so`, `load_nif`
attached it, and `nif_ping()` returned `pong`. **Two portability gotchas were caught — this is exactly
what the keystone exists to freeze before downstream depends on it:**

**Gotcha 1 — `erl_nif.h` is NOT at `code:lib_dir(erts, include)` on this layout.** On this homebrew OTP 29
install `code:lib_dir(erts, include)` returns
`…/lib/erlang/lib/erts-17.0.2/include` — a path with **no `erl_nif.h`**. The header actually lives at
`…/lib/erlang/erts-17.0.2/include/erl_nif.h` and `…/lib/erlang/usr/include/erl_nif.h`. **Frozen resolver
(`erts_include/0`)** — try candidates in order, pick the first where `erl_nif.h` exists:

```erlang
erts_include() ->
    Root = code:root_dir(),
    Vsn  = erlang:system_info(version),
    Candidates = [
        filename:join([Root, "erts-" ++ Vsn, "include"]),   %% confirmed on macOS OTP 29 + Linux
        filename:join([Root, "usr", "include"]),            %% confirmed fallback on macOS OTP 29
        code:lib_dir(erts, include)                          %% brief's suggestion — some layouts only
    ],
    hd([D || D <- Candidates, filelib:is_file(filename:join(D, "erl_nif.h"))]).
```

**Gotcha 2 — macOS clang REQUIRES `-undefined dynamic_lookup`; Linux gcc must NOT get it.** A NIF
references `enif_*` symbols resolved at load time from the host `beam.smp`, so they are undefined at link
time. Linux `ld` allows undefined symbols in a shared object by default; macOS `ld` **rejects** them. On
this host, plain `cc -shared -fPIC …` **failed**:

```
Undefined symbols for architecture arm64:
  "_enif_make_atom", referenced from: _nif_ping …
  "_enif_open_resource_type", referenced from: _load …
```

and only compiled once `-undefined dynamic_lookup` was added. **Frozen `os:type()`-selected flag vector
(`cflags/0`):**

```
common : cc  -shared -fPIC -O2 -I<erts_include>  -o <Dir>/twocore_rt_mem_nif.so  <Dir>/twocore_rt_mem_nif.c
{unix,darwin} : + -undefined dynamic_lookup        %% MANDATORY — confirmed live (pong)
{unix,linux}  : + (nothing)                        %% -shared suffices; confirmed behaviour on CI gcc
```

Fallback (frozen, if a future macOS `ld` rejects `-shared`): `-bundle -flat_namespace -undefined suppress`
(the classic rebar3 port-compiler recipe). The Linux half runs for real on CI `ubuntu-latest` gcc; the
macOS half is proven above.

### 3.6 `test/twocore/runtime/rt_mem_nif_build_test.gleam` — the `nif_ping` proof

The Gleam test module. Frozen `@external`s + result type:

```gleam
pub type BuildResult { Loaded  SkipNoToolchain  BuildError(String) }

@external(erlang, "twocore_rt_mem_nif_build_ffi", "compile_load_probe")
fn compile_load_probe() -> BuildResult

@external(erlang, "twocore_rt_mem_nif_build_ffi", "which")
fn which(exe: String) -> Result(String, Nil)

@external(erlang, "twocore_rt_mem_nif_ffi", "nif_ping")
fn nif_ping() -> Atom       // the shim's NIF; stub raises until load
```

The headline test compiles + loads the `nif_ping` probe and asserts `nif_ping()` marshals to the atom
`pong` (skip-categorized when no `cc`) — §5.1. This is the same assertion on CI gcc and macOS clang.

### 3.7 `.gitignore` — build artifacts (open seam #5, resolved)

The tempdir `.so` lives under `$TMPDIR` (outside the repo), so it is never staged — but a dev compiling
in-tree (under `c_src/`) must never accidentally commit an artifact. The ignore is **anchored to the
in-tree build location only** (`/c_src/*.so` etc.), **not** a bare `*.so`/`*.dylib` glob (lesser-a): a bare
glob would silently swallow the deployment follow-on's committed `priv/twocore_rt_mem_nif.so`, so the
follow-on's `priv/*.so` is left **un-ignored** and committable (the follow-on `git add -f`s it only if a
future glob ever widens). Frozen block appended after the existing `*.beam` / `*.ez` entries
(`.gitignore:1-2`):

```
# Phase-15 tier-N C NIF build artifacts — anchored to the in-tree build location ONLY, so a future
# committed priv/*.so from the packaging follow-on is NOT silently ignored (the follow-on git add -f's if
# these ever widen). The test-time build compiles under $TMPDIR (outside the repo) and is never staged.
/c_src/*.so
/c_src/*.dylib
/c_src/*.o
```

### 3.8 `rt_mem_nif.gleam` stays the paged-delegate (UNTOUCHED)

The keystone proves the pipe, not the water: `src/twocore/runtime/rt_mem_nif.gleam` is **not edited**. Its
bodies keep delegating to `rt_mem` (byte-identical, spec-correct by construction), it holds **no**
`@external` to the shim yet, and its existing differential suite (`rt_mem_nif_test.gleam`'s `nif ≡ paged ≡
oracle` over a randomized op trace, `run_differential :271`, `diff_loop :284`) stays green **unchanged** —
proving the tier is undisturbed. The shim is inert (nothing on the default path force-loads it), so its
mere presence changes no emission and no tier behaviour.

---

## §4. The work (ordered, buildable)

1. **`c_src/twocore_rt_mem_nif.h`** (§3.1) — the `twocore_mem_t` reserved-buffer struct, the
   `TWOCORE_RT_MEM_NIF_RESOURCE` name, and the frozen ABI-contract doc block (LE, no-wrap bounds,
   trap-before-write, grow-in-reservation).
2. **`src/twocore_rt_mem_nif_ffi.erl`** (§3.2, §3.3) — `-on_load(init/0)` (env → `priv/`, soft `ok`) + the
   16-export stub table (`nif_ping/0` + `nif_available/0` (stub returns `false`) + the 14 op stubs, each
   `erlang:nif_error(nif_not_loaded)`), with `////`-equivalent Erlang module + per-export docs.
3. **`test/twocore_rt_mem_nif_build_ffi.erl`** (§3.4, §3.5) — `which/1`, `cc/0`, `compile_load_probe/0`,
   `compile_load_cnif/0`, the embedded `nif_ping` probe source, `erts_include/0` (robust), `cflags/0`
   (`os:type()`), and the copied `run_port/3` + `fresh_dir/1`.
4. **`test/twocore/runtime/rt_mem_nif_build_test.gleam`** (§3.6, §5) — the `BuildResult` type, the three
   `@external`s, the headline compile+load+ping test, and the gate-categorization test.
5. **`.gitignore`** (§3.7) — the build-artifact block.
6. `gleam format` (formats the new `.gleam` test only — the `.erl`/`.h` are hand-written, not
   gleam-formatted) → `gleam build` (**zero warnings** — the inert shim compiles clean, no unused) →
   `gleam test` (the `nif_ping` proof green on this host; the existing `rt_mem_nif` differential still
   green) → announce `«NIF-BUILD-FROZEN»` in `state.md` with the four frozen surfaces and the exact
   running total re-confirmed.

---

## §5. Tests (`test/twocore/runtime/rt_mem_nif_build_test.gleam`)

Objective tests against the **toolchain contract**, not change-detectors: the proof is *does a real C NIF
compile and load and answer* — not a golden of C source or emitted Core (S7). Model the skip idiom on
`emit_elixir_bindings_test.gleam:308-316`.

1. **`nif_ping_compiles_loads_and_returns_pong_test` (the headline, toolchain-gated).**
   `case compile_load_probe() { SkipNoToolchain -> io.println("[s15-01] no C toolchain (cc/gcc) on PATH —
   tier-N NIF build+load SKIPPED (categorized, S6)"); Nil ; BuildError(t) -> panic as t ; Loaded ->
   nif_ping() |> should.equal(atom.create("pong")) }`. On a host with `cc`/`gcc` (CI gcc, dev clang) this
   compiles the probe, `load_nif`s it, and asserts the round-tripped atom is `pong`; absent a toolchain it
   is a **categorized skip that passes** (never a false green); a compile/`load_nif` failure is a **loud**
   test failure (the pipe is broken). This is the `«NIF-BUILD-FROZEN»` live proof.

2. **`gate_categorizes_toolchain_absence_test` (the skip logic, toolchain-independent).** The
   no-`cc`-host branch is only *taken* where a toolchain is genuinely absent (CI/dev always have one), so
   assert the **categorization logic** directly, independent of ambient `cc`: `which("cc-that-does-not-exist-xyz")
   |> should.equal(Error(Nil))` — proving the `os:find_executable` gate returns the `Error` that
   `compile_load_*` maps to `SkipNoToolchain`. (Mirrors why the Elixir arm is trusted to skip: the gate,
   not the toolchain, is what's asserted.)

3. **Resource ABI / `.h` well-formedness — proven by test 1's compile.** The `.h` is a C artifact with no
   independent Gleam assertion; its correctness (the `twocore_mem_t` struct compiles, the resource type
   registers, `ERL_NIF_INIT(twocore_rt_mem_nif_ffi, …)` links and dispatches) is proven **cross-platform**
   by test 1 succeeding — because the probe `.c` `#include`s the committed `.h`, opens the resource type,
   and only then can return `pong`. A malformed struct or a wrong `ERL_NIF_INIT` module atom fails the
   compile or the `nif_ping` dispatch, failing test 1.

4. **Default suite undisturbed (the paged-delegate is byte-identical) — the existing
   `rt_mem_nif_test.gleam`.** No new assertion is authored here; the requirement is that the existing
   tier-N differential (`nif ≡ paged ≡ oracle`, `run_differential :271`) **stays green unchanged**, since
   `rt_mem_nif.gleam` is untouched and the shim is inert. Verified by the full `gleam test` run (DoD §6.5).

> Not this unit's tests (deferred, and explicitly so): the per-op `nif ≡ paged ≡ oracle` differential
> against the **real** C NIF (S15-02, via `compile_load_cnif/0`), the C bounds-check security fuzz
> (S15-04), the unchecked-emit flip (S15-03), and the benchmark (S15-05). The keystone asserts the *pipe*.

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. **The `nif_ping` proof is green (or categorized-skip).** On `cc`/`gcc` hosts (CI ubuntu gcc, dev
   macOS clang — the macOS half proven live in §3.5) `nif_ping` compiles into a loadable `.so`,
   `load_nif` attaches it, and `nif_ping()` returns `pong` (test 1); a toolchain-less host is a
   **categorized skip that passes** (never a false green); the gate-categorization test (test 2) is green.
2. **Docs for the next agent.** Module-level docs on the shim (`twocore_rt_mem_nif_ffi`) and the build FFI
   (its trust boundary, the gate, the tempdir lifecycle); a `///`-per-export contract on every stub
   (name → what the NIF will do, its `{ok,_}/{error,oob}` shape) and on the `.h`'s struct + ABI table; and
   `///` on the Gleam test's `BuildResult`, `@external`s, and helpers. The `.h` documents the reservation
   model + LE/no-wrap/trap-before-write invariants the C core must honor.
3. **`gleam format --check src test` clean** (the new `.gleam` test file formatted; the hand-written
   `.erl`/`.h` are outside `gleam format`'s scope).
4. **`gleam build` zero warnings** — the inert shim + build FFI compile clean (no unused import/var/export).
5. **Default emission + tier behaviour byte-identical / undisturbed.** `rt_mem_nif.gleam` is untouched and
   the shim is inert, so the existing `rt_mem_nif_test.gleam` differential, the whole corpus/conformance
   suite, and every `emit_mem_*` seam stay green and unchanged — no `.core` for any module changes, the
   four Safe-forbidden gates are not touched (S5), and `emit_core` is not touched.
6. **`«NIF-BUILD-FROZEN»` announced in `state.md`** with the four frozen surfaces recorded — the
   `twocore_mem_t` resource ABI (§3.1), the 16-export shim table (the 14 `nif_`-prefixed ops + `nif_ping` +
   `nif_available`, incl. the stubbed unchecked heads, the combined-`Ea` argument shape — §3.3),
   the `.so` name / `ERL_NIF_INIT` module `twocore_rt_mem_nif_ffi` / `-on_load` env-then-`priv/`
   convention (§3.2, §3.5), and the build-gate signature `which/cc/compile_load_probe/compile_load_cnif`
   (§3.4) — plus the exact running total re-confirmed.

---

## §7. What it leaves (handoff to downstream)

- **S15-02 (native backend — the heart):** writes `c_src/twocore_rt_mem_nif.c` implementing every frozen
  NIF (§3.3) as `static` C over the reserved `twocore_mem_t` buffer — LE + no-wrap `ea + n <= byte_len`
  bounds **in C**, trap-before-write, `ERL_NIF_INIT(twocore_rt_mem_nif_ffi, …)`, the resource type opened
  in `load` under `TWOCORE_RT_MEM_NIF_RESOURCE` — and rewrites `src/twocore/runtime/rt_mem_nif.gleam`'s
  bodies to `@external` into the frozen shim, wrapping `Option`/`Result`(`{error,oob} →
  MemoryOutOfBounds`)/`InstanceState` threading/`rt_meter` fuel around the NIFs while **preserving every
  frozen head**. It drives its per-op `nif ≡ paged ≡ oracle` differential through the frozen
  `compile_load_cnif/0` gate (skip-categorized on absence). It **confirms the reservation sizing** (open
  seams #2/#3) *within* the frozen struct — a freeze amendment if it needs more, raised before building.
- **S15-03 (unchecked wiring):** the `nif_load_unchecked`/`nif_store_unchecked` exports are **already in
  the frozen shim table** (stubs), so S15-03 owns only the one-line `emit_core.gleam`
  `mem_supports_unchecked :1765` whitelist add (`|| mem_module == profiles.mem_module_for(Nif)`) and the
  `emit_unchecked_test.gleam:77` flip (nif *emits* unchecked, no longer falls back) — no shim edit.
- **S15-04 (node-safety + matrix):** the C bounds-check adversarial **fuzz** (random/edge `ea`+`n` at and
  past `byte_len` and at `grow` watermarks, proving the trap fires and nothing reads/writes outside
  `[0, byte_len)` — the tested trust boundary, S3) + the full `cell_nif` corpus differential exercising
  native memory, all driven through the frozen build gate.
- **S15-05 (capstone):** the measured **nif column** in `docs/phase-4-benchmark.md`, `docs/phase-15-tier-n.md`
  (methodology, honest ceiling, the prebuilt `priv/*.so` deployment follow-on the `-on_load` `priv/` path
  is already wired for), the conformance SVG regen, and the status roll-up.

**Freeze summary.** After this unit, every downstream unit binds to a proven pipe: a resource struct, a
16-export shim, a `.so`/`load_nif`/`ERL_NIF_INIT` convention, and a `cc`-gated build harness that
**already compiles and loads a real NIF on macOS clang and (on CI) Linux gcc** — with the two portability
gotchas (`erl_nif.h` location, macOS `-undefined dynamic_lookup`) caught and frozen here rather than
discovered mid-S15-02.
