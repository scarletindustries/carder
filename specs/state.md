# Implementation State — the live ledger

> The swarm's shared ledger for **the phase currently in flight**. Before claiming work, read it;
> after finishing, update it. It is a *working* file, not a history archive — completed phases are
> compacted into [`01-status.md`](01-status.md) once proven, and this file resets to the template
> below for the next phase.
>
> **How to use this file:** [`03-phase-workflow.md`](03-phase-workflow.md) §7.
> **Where we are:** [`01-status.md`](01-status.md) · **What's next:** [`02-roadmap.md`](02-roadmap.md)
> · **Architecture:** [`00-high-level.md`](00-high-level.md)

**Legend — unit status:** `unclaimed` · `in-progress (name)` · `blocked (on …)` · `done`
**Legend — freeze milestone:** a published, compiling type/signature stub that unblocks downstream
units. Announce it here the moment it lands (`FROZEN ✓` / `published ✓`).

---

## Current phase

**Phases 11, 12, 13 & 14 are proven on `main` and compacted into [`01-status.md`](01-status.md) §3.** One
follow-on phase remains, scoped + adversarially-validated: **Phase 15** — production tier-N C NIF. This
ledger tracks Phase 15.

---

### ▶ Phase 15 — Production C NIF for tier-N linear memory

Overview: [`phase-15/00-overview.md`](phase-15/00-overview.md). Goal: replace the paged-delegating bodies
of `rt_mem_nif` with a real `erl_nif` C backend over a reserved raw byte buffer — **bit-identical to the
paged reference for every access** (the differential is the proof) — plus the tier-N unchecked fast path.
Unsafe-only, Safe-forbidden (the 4 gates preserved), un-`--link`-able. Decisions `S1–S8`; units
`S15-01 … S15-05`. All prior-phase decisions + the invariants
([`03-phase-workflow.md`](03-phase-workflow.md) §8) still hold.

**Baseline entering Phase 15** (keystone re-confirms on landing): **2,080 gleam tests / 0 fail** ·
`gleam build` zero warnings · `gleam format` clean · WASM conformance **47,734 pass / 683 skip / 0 fail**
(Safe ≡ Unsafe, every `state_strategy × mem_tier`).

**Scoping critique verdict:** FIX-FIRST → fixed. Blockers resolved before freeze: the frozen NIF ABI is
**`nif_`-prefixed + a combined bignum `Ea`** (avoids the keystone/S15-02 self-conflict AND the `size/1`
autoimport collision); the C bounds-check is **overflow-safe for memory64** (guarded subtractions +
`enif_get_uint64` + 64-bit-address fuzz vectors — the previous check was a host escape); a **runtime
paged-delegate fallback** is kept when the `.so` isn't loaded (preserves bare-BEAM runs-anywhere, no
`cc`-absent hard-fail — native when loaded, paged-delegate otherwise); the benchmark reuses the frozen
`erts_include/0` resolver + mandatory `-undefined dynamic_lookup` on macOS.

### Freeze milestones

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«NIF-BUILD-FROZEN»` — `c_src/twocore_rt_mem_nif.h` resource-struct + op ABI (nif_-prefixed, combined `Ea`, 16 exports incl. `nif_ping`+`nif_available`), the `src/twocore_rt_mem_nif_ffi.erl` shim export table + `on_load`/`.so`-name convention, and the `test/twocore_rt_mem_nif_build_ffi.erl` `cc`-gated compile+`load_nif` harness — proven live by a `nif_ping` NIF compiling+loading on CI gcc + macOS clang. `rt_mem_nif.gleam` stays the byte-identical paged-delegate at this unit | S15-01 | **FROZEN ✓ (S15-01)** | S15-02, S15-03, S15-04, S15-05 |

**`«NIF-BUILD-FROZEN»` — the four frozen surfaces S15-02..05 bind to (proven live, macOS clang OTP 29 / erts 17.0.2):**
1. **Resource ABI** — `c_src/twocore_rt_mem_nif.h`: `twocore_mem_t { size_t byte_len; size_t max_bytes; unsigned char data[]; }` (reserved buffer, moving watermark, never realloc'd) + resource-type name `"twocore_rt_mem_nif_resource"`.
2. **Shim export table** — `src/twocore_rt_mem_nif_ffi.erl`: 16 `nif_`-prefixed exports (`nif_ping/0`, `nif_available/0` [stub returns `false`], + the 14 op stubs incl. the stubbed `nif_load_unchecked/5`+`nif_store_unchecked/4`), each op-stub `erlang:nif_error(nif_not_loaded)`; combined-`Ea` argument shape (Gleam computes `ea=addr+offset` no-wrap bignum, C never re-adds).
3. **`.so`/`load_nif`/`ERL_NIF_INIT` convention** — `.so` basename `twocore_rt_mem_nif`; `ERL_NIF_INIT` module atom = the shim = **`twocore_rt_mem_nif_ffi`** (NOT `twocore_rt_mem_nif`); `-on_load` resolves via `TWOCORE_RT_MEM_NIF_SO` env override → `priv/twocore_rt_mem_nif`, soft-`ok`.
4. **Build-gate signature** — `test/twocore_rt_mem_nif_build_ffi.erl`: `which/1`, `cc/0` (cc→gcc), `compile_load_probe/0` (embedded `nif_ping`), `compile_load_cnif/0` (the committed `.c`, for S15-02) → `loaded | skip_no_toolchain | {build_error, Bin}`. **Frozen `erts_include/0` resolver** (candidate list: `erts-<vsn>/include` → `usr/include` → `filename:join(code:lib_dir(erts),"include")`; the bare `code:lib_dir(erts,include)` is header-less on homebrew OTP 29) + **`os:type()` cflags**: common `-shared -fPIC -O2 -I<inc>`, `{unix,darwin}` **MANDATORY `-undefined dynamic_lookup`**, `{unix,linux}` nothing extra.

Live proof this host: `cc -shared -fPIC -O2 -undefined dynamic_lookup -I/opt/homebrew/Cellar/erlang/29.0.2/lib/erlang/erts-17.0.2/include -o <tmp>/twocore_rt_mem_nif.so <tmp>/twocore_rt_mem_nif.c` → `load_nif` attaches → `compile_load_probe()=loaded`, `nif_ping()=pong`, `nif_available()=false` (stub). Without `-undefined dynamic_lookup`: `ld: Undefined symbols … _enif_make_atom` (the frozen macOS gotcha, confirmed).

### Units

| Unit | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|
| **S15-01** Keystone: freeze the native toolchain path (`nif_ping`) | **done (keystone)** | — | `«NIF-BUILD-FROZEN»`; the shim + build-gate proven to compile+load on gcc + clang; `rt_mem_nif.gleam` untouched (byte-identical). |
| **S15-02** Native backend (C core + Gleam `@external`, the heart) | `done` | `«NIF-BUILD-FROZEN»` | `c_src/twocore_rt_mem_nif.c` (all 16 exports over a reserved ERTS-resource buffer; LE, overflow-safe memory64 guarded-subtraction bounds, trap-before-write, grow-in-reservation) + `rt_mem_nif.gleam` all 37 heads `native-if-nif_available()-else-rt_mem` (+ 4 `*_unchecked` heads); ~800-step nif≡paged≡oracle differential proven (macOS clang; realness confirmed by bug-injection). **⚠ S15-04 caveat:** ERTS refuses `load_nif` while nif resources are live — reuse the loaded NIF + GC before reload. `mem_init` C symbol (`nif_init` reserved by `ERL_NIF_INIT`). +11 tests. |
| **S15-03** Unchecked fast path wiring | `done` | S15-02 | `Nif` added to `emit_core.mem_supports_unchecked` (tier-N BCE fast arm emits `nif_*_unchecked`; slow arm stays checked — trap-preservation held) + `emit_unchecked_test` flipped. +2 tests. **⚠ S15-04 must fix (found here):** native `init_data` OOB raises `badarg` not the "out of bounds memory access" trap (3 `data.wast` cases fail on the native path); and loading the NIF from a module sorting before `conformance` poisons the `cell_nif` matrix (ordering-sensitive — unload/gc). |
| **S15-04** Node-safety fuzz + full `cell_nif` matrix | `unclaimed` | S15-02 | C bounds-check fuzz (incl. 64-bit-address vectors + cross-resource copy) proving no host escape; `combos.cell_nif` exercises native; the 4 Safe-forbidden gates + `--link` exclusion re-confirmed. |
| **S15-05** Capstone | `unclaimed` | all above | **PHASE 15 PROVEN.** Bit-identical tier + unchecked ceiling + security fuzz + toolchain-gated CI (native under gcc, categorized-skip when no `cc`); measured `nif` column in `docs/phase-4-benchmark.md` (honest ceiling, no hero number); SVG; `docs/phase-15-tier-n.md`; `01-status.md`. |

### Landing log

_(one line per landing: `unit — N tests (was M, +K), conformance p/s/f, 0 warnings, format clean, byte-identical`)_

- S15-01 keystone — 2082 tests (was 2080, +2: the `nif_ping` compile+load proof + the gate-categorization test), conformance 47734/683/0, 0 warnings, format clean, `rt_mem_nif.gleam` byte-identical. `«NIF-BUILD-FROZEN»` proven live on macOS clang: `nif_ping` compiled + `load_nif` attached + returned `pong`. The `c_src/*.c` (S15-02) is NOT built; only the embedded probe `.c` compiles this unit.

---

## Template (copy this block when the next phase starts)

> Phase N — «title». Goal & honest scope: see the phase overview. Decisions: continue the letter series
> (Phase 13 = `Q`, 14 = `R`, 15 = `S`, next = `T`; `#1` = keystone, last = honest scope). All prior-phase
> decisions and the invariants in [`03-phase-workflow.md`](03-phase-workflow.md) §8 still hold.

### Freeze milestones

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«X-FROZEN»` — … | 01 | `unclaimed` | … |

### Units

| Unit | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|
| **01** Interface freeze (keystone) | `unclaimed` | — | … |
| **…** | `unclaimed` | … | … |
| **N** Capstone | `unclaimed` | all above | **PHASE N PROVEN.** … |

### Landing log

_(one line per landing: `unit — N tests (was M, +K), conformance p/s/f, 0 warnings, format clean, byte-identical`)_
