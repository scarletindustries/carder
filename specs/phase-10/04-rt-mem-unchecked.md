# Phase 10 · Unit 04 — `rt_mem` / `rt_mem_atomics` unchecked entry points (the check-free fast path)

> **One owner · the BCE runtime chain (04 → 05 → 06) · single-owner-additive.** Freeze dep:
> `«MEM10-FROZEN»` (unit 01) publishes the **unchecked entry-point signatures** (keystone §D) and the
> additive `MemLoadUnchecked`/`MemStoreUnchecked` IR nodes that (at the freeze) lower like the checked
> nodes. Read [`00-overview.md`](00-overview.md) (**N1**, **N4**, **N5**) and
> [`01-keystone.md`](01-keystone.md) (**§D frozen unchecked signatures**) first, then the checked
> interface this unit twins: `src/twocore/runtime/rt_mem.gleam` (`load`/`store`/`t_load`/`t_store`/
> `load_at`/… + the private `mem_load`/`mem_store` core) and `src/twocore/runtime/rt_mem_atomics.gleam`
> (`load`/`store`/`load_bytes`/…). This unit replaces the unit-01 stub bodies with genuinely
> **check-free** bodies that skip the `MemoryOutOfBounds` compare and go straight to the byte access —
> yet stay **BEAM-memory-safe** on a (guard-impossible) OOB (**N5**): paged slices an **immutable
> binary**, atomics indexes an ERTS-native **`atomics` array** — so a hypothetical range-analysis bug
> degrades to a *trap* (a caught BEAM error) or a *contained wrong value*, **never** memory corruption
> or a host escape. It touches **no `nif`** (tier-N has no unchecked twin — **N5**).

---

## Context

Range-based BCE (unit 06) versions an affine-access loop into `if all_in_bounds { fast } else
{ checked }`, and the **fast** arm lowers its accesses to `MemLoadUnchecked`/`MemStoreUnchecked`
(unit 05 → these entry points). Soundness rests on **loop versioning** (N4/N6), not on the runtime:
the fast arm runs **only** when the runtime range-guard has proven the whole access range in-bounds,
so an actual OOB is impossible on the fast path. "Unchecked" therefore means one precise thing —
**no explicit per-access bounds compare and no `Result`-wrapped trap path** — *not* "unsafe memory
access." The removed compare is `ea + bytes > byte_len`; **everything else is reused verbatim** from
the checked path (the same little-endian byte assembly / disassembly, the same sign/zero-extension,
the same chunk rebuild on a paged store). And crucially, if the guard were ever wrong, the underlying
primitive is still memory-safe on the BEAM (§B) — the fail-safe that makes shipping an unchecked path
on `paged` + `atomics` sound even though the compiler, not the runtime, carries the correctness.

This unit is the third link in the BCE chain. Unit 01 froze the signatures (§D) and landed **stub
bodies that delegate to the checked path** (unwrapping the `Result` — sound, just not yet fast). This
unit swaps those stubs for the real check-free bodies and pins them to the checked oracle with a
**differential** (§C).

---

## Files owned (single-owner-additive)

- `src/twocore/runtime/rt_mem.gleam` — **EXTEND (owner-additive).** Replace the unit-01 stub bodies of
  the paged unchecked twins with check-free bodies: `load_unchecked`, `store_unchecked`,
  `t_load_unchecked`, `t_store_unchecked`. These are new **public** heads that call the existing
  module-private core (`current_mem`/`from_dynamic`, `read_bytes`, `decode_signed`/`decode_unsigned`,
  `encode_le`, `write_bytes`, `mem_to_dynamic`, the `rt_state.mem`/`with_mem`/`mem_put` seam) — no
  edit to the frozen pure `mem_*` core, the LE codec, or any checked head.
- `src/twocore/runtime/rt_mem_atomics.gleam` — **EXTEND (owner-additive).** The atomics unchecked
  twins: `load_unchecked`, `store_unchecked`, `t_load_unchecked`, `t_store_unchecked`, calling the
  existing private core (`current_atomics`/`project`, `gather`, `scatter`, `decode_signed`, the
  `atomics_to_dynamic`/`rt_state.with_mem` seam) — no edit to the pure `a_*` core or the FFI shim.
- `test/twocore/runtime/rt_mem_test.gleam` **and** `test/twocore/runtime/rt_mem_atomics_test.gleam`
  — **EXTEND** (or a new `test/twocore/runtime/rt_mem_unchecked_test.gleam`): the differential vs the
  checked oracle + the OOB BEAM-safety cases + the threaded-twin cases.

**Explicitly NOT owned:** `src/twocore/runtime/rt_mem_nif.gleam` (tier-N) gains **no** unchecked twin
(N5 — an unchecked *native* access could corrupt the node; Safe forbids nif; BCE's win is on atomics).
Unit 05's lowering emits the **checked** nif path for an unchecked node on the nif tier (the versioned
fast and slow loops are byte-identical there — a documented, sound no-op).

**Depends on:** `«MEM10-FROZEN»` (unit 01) — the frozen §D signatures and the stub bodies this unit
replaces. No dependency on unit 05/06 (they consume these entry points; they do not shape them).

---

## A. The unchecked entry points (frozen §D signatures, real bodies)

Four public heads per tier, mirroring the checked `load`/`store`/`t_load`/`t_store` **minus the
`Result`/trap** (keystone §D). Same operand order, same meaning of every parameter as the checked
head they twin; consult those heads' doc comments for the codec/width/offset contract, which is
**identical** here.

```gleam
// rt_mem (paged) and rt_mem_atomics (atomics) — the unchecked twins:
pub fn load_unchecked(bytes, signed, result_width, addr, offset) -> Int          // no Result
pub fn store_unchecked(bytes, addr, value, offset) -> Nil                          // no Result
pub fn t_load_unchecked(st, bytes, signed, result_width, addr, offset) -> Int     // threaded twin
pub fn t_store_unchecked(st, bytes, addr, value, offset) -> InstanceState          // threaded twin
```

**Paged bodies (`rt_mem.gleam`)** — reuse the private core, drop only `in_bounds`:

- `load_unchecked` — `let ea = addr + offset` then `read_bytes(current_mem(), ea, bytes)` and
  `decode_signed(raw, bytes, result_width)` (when `signed`) / `decode_unsigned(raw, bytes)` (else),
  returning the raw `Int`. This is `mem_load` with the `case in_bounds(…)` wrapper stripped.
- `store_unchecked` — `let ea = addr + offset` then `write_bytes(current_mem(), ea, encode_le(value,
  bytes))` and `rt_state.mem_put(mem_to_dynamic(updated))`, returning `Nil`. This is `mem_store` +
  the cell write-back with the `case in_bounds(…)` wrapper stripped. **The chunk rebuild + write-back
  remain** — the check is what is removed, not the rebuild.
- `t_load_unchecked` — the same load over `from_dynamic(rt_state.mem(st))`; leaves `st` untouched.
- `t_store_unchecked` — the same store over `from_dynamic(rt_state.mem(st))`, returning
  `rt_state.with_mem(st, mem_to_dynamic(updated))` — a **rebound** record (paged memory is immutable,
  so the new `Mem` differs), exactly as `t_store` returns `Ok(st')`.

**Atomics bodies (`rt_mem_atomics.gleam`)** — reuse the private core, drop only `in_bounds`:

- `load_unchecked` — `let ea = addr + offset`, `let raw = gather(current_atomics(), ea, bytes)`, then
  `decode_signed(raw, bytes, result_width)` when `signed` else `raw` (gather already yields the
  unsigned raw — the zero-extension is identity on the bit pattern). This is `a_load` minus the
  `case in_bounds(…)`.
- `store_unchecked` — `let ea = addr + offset`, `scatter(current_atomics(), ea, value, bytes)`,
  returning `Nil`. **In-place `ref` mutation → no `mem_put`** (like the checked `store`). This is
  `a_store` minus the `case in_bounds(…)`.
- `t_load_unchecked` — the same load over `project(st)`; leaves `st` untouched.
- `t_store_unchecked` — the same store over `project(st)`, returning the **same** `st` (the `ref` is
  mutated in place, so the `mem` `Dynamic` is unchanged — exactly as `t_store` returns `Ok(st)`).

Note the threaded-store return-shape asymmetry is **inherited** from the checked twins and is correct:
paged `t_store_unchecked` returns a rebound record, atomics `t_store_unchecked` returns the same
record. Both satisfy the frozen `-> InstanceState` head.

### `_at` multi-memory twins — deferred (recommendation)

The unchecked IR nodes carry a `mem: Int`. **Recommend NOT shipping `load_unchecked_at`/
`store_unchecked_at`/`t_*_unchecked_at` in this unit.** Affine-access loops that BCE recognizes target
the default memory (`mem == 0`) in the overwhelming common case, and the multi-memory `_at` family is
a niche of a niche. Unit 05's lowering should therefore:

- for `mem == 0`, emit `load_unchecked`/`store_unchecked` (the index-0 unchecked path this unit ships);
- for `mem > 0`, **fall back to the checked** `load_at`/`store_at` (sound — a versioned fast arm that
  keeps the check for a non-default memory is still correct; it just isn't accelerated).

This keeps unit 04's surface minimal and loses nothing measurable. If unit 05/06 later find a
multi-memory affine loop worth accelerating, the `_at` unchecked twins are a trivial additive
follow-on (project via `mem_at`/`t_mem_at` instead of `current_mem`/`project`, same body). This unit
states the deferral so unit 05 does not block on a surface it does not need.

---

## B. Semantics + the BEAM-safety argument (the load-bearing section)

### B.1 What "unchecked" removes, and what it keeps

An unchecked access is **byte-for-byte the checked access with one line deleted** — the
`ea + bytes > byte_len` compare (paged `in_bounds`, atomics `in_bounds`) and the `Result` wrapper it
gates. The byte assembly (`read_bytes` / `gather`), disassembly (`encode_le` / `scatter`), the
little-endian codec, the sign-vs-zero extension keyed on `result_width`, and — on a paged store — the
chunk rebuild and cell write-back are **all reused unchanged**. Therefore, on any **in-bounds** input,
`load_unchecked(…)` returns the *identical bits* to `unwrap(load(…))` and `store_unchecked(…)` leaves
memory *byte-identical* to `store(…)` — by construction, because the only difference is a branch that
is not taken on in-bounds inputs. The differential (§C) proves this rather than asserting it (it guards
against a copy-paste slip in the unchecked body — a dropped `decode`, a wrong reuse, a lost write-back).

### B.2 Why it stays BEAM-memory-safe on a (guard-impossible) OOB — **N5**

The whole point of shipping unchecked accesses on `paged` + `atomics` (and **not** on `nif`) is that
these two tiers are memory-safe **at the primitive level**, independently of the removed compare. If
the loop-versioning guard (unit 06) were ever wrong and drove an unchecked access out of bounds, the
worst case is a **trap** (a caught BEAM error) or a **contained wrong value**, never corruption of
another instance, never a native out-of-bounds read/write, never a node crash from memory unsafety.

- **Paged — immutable-binary slice.** A paged load routes through `read_bytes` → `read_in_chunk` /
  `read_span` → `take`, and `take` is `bit_array.slice(bin, at, len)` under `let assert Ok(_)`. A slice
  that runs past the end of the chunk binary returns `Error(Nil)`, so the `let assert` raises a
  **catchable BEAM error** (surfaced as a trap). An OOB whose chunk is simply **absent** returns `n`
  zero bytes (a contained wrong value, not a raise). A paged unchecked store routes through
  `write_bytes` → `write_loop` → `chunk_for_store` (materialises a fresh zero chunk if absent) →
  `splice_chunk`; the intra-chunk offset is `ea % cs ∈ [0, cs)` by construction and the trailing
  `take` short-circuits a negative length to `<<>>`, so it writes into a materialised chunk that is
  logically beyond `byte_len`. That stray write lives entirely inside an **immutable-binary-backed
  sparse map** owned by this process — it cannot touch another instance, and a later correctly-bounded
  load can never observe it (its chunk index is past the page watermark, so `in_bounds` on the checked
  path excludes it, and it is reclaimed with the `Mem`). **Contained, node-safe, never a host escape.**
- **Atomics — ERTS-bounds-checked array index.** An atomics access derives `ix = (ea / 8) + 1` and
  calls the ERTS-native `atomics:get/2` / `atomics:put/3`. An index **outside the physical array**
  (`ix < 1` or `ix > arity`) raises catchable `badarg` — a trap, never a native OOB. The one subtlety
  worth naming: the physical reservation `reserve` can **exceed** the logical page watermark `pages`
  (`a_fresh` reserves `max(min_pages, eff)` pages of words up front; `grow` only moves the watermark),
  so an OOB `ea ∈ [pages·page_bytes, reserve·page_bytes)` indexes a **reserved-but-logically-OOB word**
  — `atomics:get`/`put` succeed and return / mutate a *contained* word (a wrong value, not a raise).
  Because the `atomics` ref is **process-local and never shared** (G8), that stray access can never
  affect another instance, and — being ERTS-managed — can never escape the array. Only an `ea` past
  the physical reservation raises. **Contained, node-safe, never a host escape.**

So on **both** tiers the safety net is the *primitive*, not the compare: an immutable binary and an
ERTS-managed array are each memory-safe by construction. "Unchecked" removed the explicit trap path;
it did not remove the BEAM's own memory safety. This is exactly why N5 ships unchecked on paged +
atomics but keeps nif checked — a raw C NIF has no such net, so an unchecked native access *could*
corrupt the node.

### B.3 The performance shape (honest, per N8)

The removed compare is a couple of bignum comparisons; the win is **the fraction of the whole access
it represents**:

- **Paged: small.** A paged load is a chunk lookup + slice + decode; a paged store is a chunk rebuild
  (`splice_chunk`) + `dict.insert` + a pdict write-back. The rebuild/write-back **dominate**, so
  dropping the compare is a minor constant-factor trim. (BCE's paged headline is not this; Phase-9 DSE
  is.)
- **Atomics: larger.** An atomics load is 1–2 `atomics:get` + shifts/masks — **O(1)**; an atomics
  store is 1–2 read-modify-write words. The compare is a **real fraction** of an O(1) access, so
  removing it per iteration on a hot affine loop is the measurable BCE win (N8: "largest on atomics").

The doc comments on the four heads should state this (small on paged, larger on atomics) so the next
agent does not over-attribute the paged number.

---

## C. The differential-vs-checked test design (the correctness proof)

The checked heads are already validated against the flat-binary **rebuild oracle** (Phase-4 unit 04 §E:
`atomics ≡ oracle ≡ paged`), so pinning the unchecked heads to the **checked** heads transitively
asserts WebAssembly semantics for the in-bounds domain — no change-detector, spec-first (D8): the
assertion is "the unchecked path returns what the spec-validated checked path returns," and the
divergence would be a *bug in the unchecked body*.

### C.1 In-bounds differential (the key test), across the full matrix

For every **in-bounds** access, assert `load_unchecked(…) == unwrap(load(…))` and that
`store_unchecked` leaves memory byte-identical to `store` (compare `to_flat` images). Sweep the matrix:

- **width** `bytes ∈ {1, 2, 4, 8}`;
- **sign** `signed ∈ {True, False}` and **`result_width ∈ {32, 64}`** — so `i32.load8_s` (→
  `0xFFFFFF80`) is distinguished from `i64.load8_s` (→ `0xFF…FF80`); include high-bit-set stored bytes
  (`0x80`, `0xFF…`) so sign-extension is actually exercised;
- **address / offset** — aligned, unaligned, and (atomics) **word-boundary-crossing** `ea` (e.g. an
  i64 at `p ≠ 0` spanning two 64-bit words); `offset ∈ {0, small, large}` split across `addr`/`offset`;
  and the **exact boundary** — an access ending precisely at `byte_len` (the maximal in-bounds `ea`),
  the tightest in-bounds case.

**Mechanics.** Loads do not mutate, so drive the load matrix over **one** seeded memory:
`load_unchecked(…)` vs `unwrap(load(…))` on the cell path, and `t_load_unchecked(st, …)` vs
`unwrap(t_load(st, …))` on the threaded path. Stores mutate, so compare over **independent** memories:
the cleanest is the **threaded** twins — build two `InstanceState`s from the same seed, apply the same
store via `t_store_unchecked` vs `unwrap(t_store)`, and assert the two resulting records have equal
`to_flat` byte images (paged: rebound records with equal images; atomics: same-handle records with
equal images). The cell path can be covered by reseeding between the checked and unchecked run. Seed
memories via the existing `rt_mem.fresh_mem`/`rt_mem_atomics.a_fresh` + the `rt_state` seed harness the
current suites use; reuse the `to_flat`/`a_flat`/`mem_flat` image hooks the Phase-4 differential uses.

### C.2 OOB is BEAM-safe (caught, not corrupting)

For an **out-of-bounds** unchecked access, assert **containment + survival**, not "it always raises"
(per B.2, an OOB may return/write a contained value rather than raise). Wrap each OOB call in the
existing panic-rescue FFI (`twocore_rt_state_test_ffi`'s `catch_thunk` / the `twocore_rt_exn_test_ffi`
helpers — pure Gleam cannot `catch`) and assert:

1. **The VM survives** — `catch_thunk` returns (`Ok` for a contained wrong value, `Error(_)` for a
   caught BEAM error / `badarg`); the test process is not killed.
2. **No corruption of in-bounds memory** — re-read a set of **known in-bounds** bytes via the *checked*
   `load` after the OOB unchecked op and assert they are **unchanged** (a stray write, if any, landed
   in the contained logically-OOB region and did not perturb the live footprint).

Cover both OOB flavours on each tier so the argument is complete:

- **Atomics** — an `ea` past the **physical reservation** (`ix > arity`) → assert `catch_thunk` yields
  `Error(_)` (a caught `badarg`); and an `ea ∈ [pages, reserve)` → assert it returns/writes a contained
  word with the live footprint intact.
- **Paged** — an `ea` in an **absent** chunk → a contained zero read / contained stray write, footprint
  intact; and a spanning access into a **present** chunk beyond its bytes → assert `catch_thunk` yields
  `Error(_)` (the `take` `let assert` raised).

### C.3 Threaded twins thread the record correctly

Assert `t_load_unchecked` leaves `st` untouched and returns the same value as `unwrap(t_load)`; assert
`t_store_unchecked` returns a record whose `to_flat` equals `unwrap(t_store)`'s — a **rebound** record
on paged (new `Mem`) and the **same** record on atomics (in-place `ref`) — matching the checked twins'
return shape exactly.

---

## Verification (Definition of Done — D8)

Tests assert **WebAssembly semantics via the spec-validated checked oracle**, never "whatever the
unchecked impl emits" — no change-detectors.

1. **In-bounds differential (the bar).** Across the full `width × sign × result_width × addr/offset`
   matrix (§C.1, including aligned / unaligned / word-boundary-crossing and the exact-`byte_len`
   boundary): `load_unchecked(…) == unwrap(load(…))` and `store_unchecked` leaves memory byte-identical
   to `store` (`to_flat` equality) — on **both** paged and atomics.
2. **OOB is BEAM-safe (§C.2).** Every OOB flavour on each tier: the VM survives (rescued), the live
   in-bounds footprint is unchanged (no corruption), and the far-OOB case is a caught error — proving
   the N5 fail-safe (a guard bug degrades to a trap / contained wrong value, never a host escape).
3. **Threaded twins thread correctly (§C.3).** `t_load_unchecked` leaves `st` intact and matches
   `t_load`; `t_store_unchecked` matches `t_store`'s byte image with the correct return shape per tier.
4. **nif untouched.** `rt_mem_nif.gleam` is unchanged (no unchecked twin); confirm the file has no
   `*_unchecked` head (N5).
5. **Green DoD.** `gleam format --check src test` clean; `gleam build` with **zero warnings** (every
   unchecked head total — no `todo`/`panic`/`let assert` on a live path; the coercions stay
   sole-producer-sound like the checked heads); `gleam test` green (≥ the current count + the new
   tests, 0 failures). The whole existing corpus is untouched by this unit (the entry points are new
   public heads; nothing calls them until unit 05 flips the lowering), so the Phase-1…9 corpus stays
   result-identical. Every new public head carries a `///` contract doc (what it does, params, return,
   and the **BEAM-safety / no-explicit-check** note).

**Done = the unchecked differential + OOB-safety + threaded-twin suite passes** (unchecked ≡ checked
on every in-bounds access; OOB is contained/caught; twins thread correctly), not "it compiles."

---

## What this unit leaves for others

- **Unit 05 (emit)** flips `emit_core`'s lowering of `MemLoadUnchecked`/`MemStoreUnchecked` from the
  checked path (the unit-01 freeze behaviour) to **these** unchecked entry points — `load_unchecked`/
  `store_unchecked` (and the `t_*` twins under `state_strategy: Threaded`) for `mem == 0` on paged /
  atomics, the **checked** `load`/`store` fallback for `mem > 0` and for the **nif** tier — selecting
  by the linked `mem_module` exactly as it selects the checked entry point (G5).
- **Unit 06 (range-BCE)** produces the unchecked IR nodes inside the fast arm of a versioned loop; the
  runtime guarantee it relies on is precisely §B — the unchecked heads return the checked bits on every
  in-bounds access and are BEAM-safe on the (guard-impossible) OOB.
- The `_at` multi-memory unchecked twins are **deferred** (§A) — a trivial additive follow-on if a
  future multi-memory affine loop ever wants them; unit 05 falls back to checked for `mem > 0` until
  then.
