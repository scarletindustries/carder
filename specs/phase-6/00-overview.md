# Phase 6 — Overview & Shared Contracts

> **Read this after the Phase-1…Phase-5 overviews.** Every decision on those pages **still holds** —
> one owner per file, runtime layers as Gleam modules reached through the binding chokepoint with
> **no ambient authority** (D3a), per-stage error types, floats-as-bit-patterns (D5), named-label
> structured IR, the tier-O `cell` / tier-P `threaded` state strategies, the memory trust-tier
> ladder (`paged`/`atomics`/`nif`), the reference value model (`rt_ref`, forge-proof — R1), the
> shared optimizer, the two named modes (Safe/Unsafe), spec-first tests, the strict Definition of
> Done. This page adds the Phase-6 decisions **I1–I8**. Phases 1–5 are complete and green: **1212
> tests, 0 warnings, conformance `fail == 0` under every shipped `(mode × state_strategy × mem_tier)`
> binding** (Safe/Unsafe 21525 pass / 1257 skip / 0 fail), the complete standardized WebAssembly
> surface **minus SIMD** proven end-to-end, byte-identical by default, runs-anywhere.
>
> **⚠ After the scoping fan-out + adversarial critique, the canonical decisions will be reconciled in
> [`RECONCILIATION.md`](RECONCILIATION.md) (decisions S1–Sn). That file is AUTHORITATIVE — where a
> unit doc conflicts with it, RECONCILIATION.md wins. Implementer read order:
> this overview → `RECONCILIATION.md` → the unit doc.**

---

## 0. Where Phase 6 sits (the platform, one paragraph)

Phases 1–5 built a **correct, sandboxed, fast, runs-anywhere WebAssembly engine** for the **complete
standardized surface *minus SIMD*** — reference types, bulk memory & table ops, multiple memories,
non-function imports + the `spectest` module, a first-class WAT text parser. Phase 5 deliberately
**deferred three things to Phase 6** (stated, not dropped): **SIMD** (the `v128` value type + ~236
lane instructions — the single largest WebAssembly proposal, bracketed "large; defer" by high-level
§12), the **memory64 runtime** (the `IdxType` IR axis + decode/validate ship; `lower`/`link` today
*reject* a 64-bit memory with a categorized skip — R12), and **cross-module wasm→wasm function
linking** (the multi-instance registry that lets one module import another module's *functions*, the
measured conformance residual `linking.wast` never scoped). Phase 6 is the **last-mile
surface-completion phase**: it closes all three, so the WASM frontend becomes **genuinely,
completely conformant** to the standardized surface. Completing it is the precondition that turns
*JS on the BEAM via Porffor* from "largely runnable" into a buildable **Phase 7**. Like Phase 5,
Phase 6 grows the IR — kept **language-neutral** (I7) and **conformance-neutral by default** (a
Phase-1..5 module still compiles byte-identically under every mode and tier).

---

## 1. The Phase-6 goal (concrete and measurable)

> **Complete the WebAssembly standard.** Generated code correctly executes the **whole** standardized
> WebAssembly surface: (a) **fixed-width SIMD** — the `v128` value type and the ~236 standardized
> lane instructions (integer/float lane arithmetic, comparisons, bitwise ops, shifts, shuffles &
> swizzle, splat/extract/replace-lane, narrowing/widening/saturating conversions, dot product,
> boolean reductions, and the v128 memory load/store family) — **bit-exact and spec-differentially
> correct**, emulated lane-wise on the BEAM (faithful, not hardware-accelerated — I3); (b) the
> **memory64 runtime** — a 64-bit-addressed linear memory executes with i64 addressing/bounds and a
> **documented, spec-aligned page cap** (no guessed 2⁶⁴ allocation — I4); and (c) **cross-module
> function linking** — a module importing another module's exported **function** dispatches correctly
> to the other instance through a **build-constructed capability closure** (no ambient authority —
> D3a), with the `.wast` `(register …)` mechanism driving it. Every new feature is **spec-differentially
> correct** (held to a conformant engine / the `rebuild` oracle), holds under **both modes and every
> state-strategy × memory-tier** it is defined for, preserves **constant-space loops + preemption**,
> and is **conformance-neutral by default** (the existing corpus + suite stay byte-identical).

### Acceptance (owned by the capstone)

| Area | Must demonstrate |
|---|---|
| **SIMD — value & const** | `v128` is a first-class **low-level fixed-width value** (the numeric path, not terms — I2), represented as a 16-byte binary; `v128.const` and all splat/const-init forms round-trip through `.ir`; a module *without* SIMD is byte-identical to Phase-5 |
| **SIMD — integer lanes** | `i8x16`/`i16x8`/`i32x4`/`i64x2` add/sub/mul/neg/abs, min/max (s+u), avgr_u, shifts (shl/shr s+u, count masked mod lane-width), and/or/xor/not/andnot/bitselect, all comparisons (eq/ne/lt/le/gt/ge s+u), extract/replace lane (s+u where applicable), splat, all execute **two's-complement-exact** (§9.1, via `rt_num` per lane) |
| **SIMD — float lanes** | `f32x4`/`f64x2` add/sub/mul/div/neg/abs/sqrt/min/max/pmin/pmax/ceil/floor/trunc/nearest, comparisons, and the conversions (`convert`/`trunc_sat`/`demote`/`promote`/narrow/widen/extend) are **IEEE-754-exact with f32 single-rounding + spec NaN propagation/canonicalization** (min/max/pmin/pmax NaN & `-0.0` behaviour per spec) |
| **SIMD — lanewise misc** | `i8x16.shuffle` (16 immediate lane indices 0..31), `i8x16.swizzle` (OOB index → 0), narrowing (saturating), widening (low/high, s+u), `i32x4.dot_i16x8_s`, extended-multiply, `*.extadd_pairwise`, `v128.any_true`/`iNxM.all_true`, `bitmask`, `q15mulr_sat` — all spec-exact against `wasmtime`/the baked `.wast` |
| **SIMD — memory** | `v128.load`/`store`, the `load{8,16,32,64}_splat`, `load{8x8,16x4,32x2}_{s,u}` (extending), `load{32,64}_zero`, and `load/store{8,16,32,64}_lane` families route through the **bounds-checked `rt_mem` seam** → trap `MemoryOutOfBounds` on OOB (no host escape); little-endian lane layout exact |
| **memory64 runtime** | a **64-bit memory** decodes/validates/lowers/**runs**: `i64` address operands, 64-bit bounds arithmetic, offsets > 2³²; `memory.size`/`grow` return i64 page counts; growth beyond the **documented spec-aligned cap** fails (`grow → -1`) / an access beyond it **traps** exactly where the spec's `assert_trap` expects; 32-bit memories stay **byte-identical**; `memory64.wast` runs green (no more categorized skip) |
| **cross-module linking** | module B importing module A's exported **function** calls it correctly across instances via a **linker-built closure capability** (fail-closed on an unsatisfied/mismatched import → `assert_unlinkable`; **no ambient `apply` of an attacker-chosen module:atom** — D3a grep-verified); `(register "A" $a)` + a later module importing `$a`'s funcs/globals/tables/memories works; **`linking.wast` runs green** and the measured residual it represents **drops** |
| **conformance expansion (headline)** | the pinned spec suite's **skip count drops materially** as `simd/*.wast` (the large SIMD file set), `memory64.wast`, and `linking.wast` light up; **`fail == 0` and `pass` rises**, reported **honestly with a categorized residual** and an **empirical `wast2json`-convertibility + residual audit at the pin** (R16); the new surface is **differentially checked against `wasmtime`** |
| **conformance-neutral + all-tier** | the entire Phase-1..5 acceptance corpus + previously-passing suite stay **byte-identical** under both profiles and every `(state_strategy × mem_tier)`; the new surface is green under the matrix it is defined for |

### Honest scope (I8 — do not overstate)

- **SIMD is emulated lane-wise; there is no hardware SIMD and no speed claim (I3).** The BEAM has no
  vector unit. `rt_simd` decodes a 16-byte binary into lanes, applies the per-lane op **reusing
  `rt_num`'s exact scalar semantics**, and re-encodes. This is **faithful** (bit-exact, spec-
  differentially correct) but **not fast** — matching the platform's governing "faithfulness beats
  raw speed" constraint and the tier-P `bif` numerics posture. A real-SIMD **tier-N NIF** is deferred
  (like tier-N memory): the interface admits it, we do not build it.
- **memory64 ships a documented, spec-aligned page cap — not 2⁶⁴ allocation (I4, R12's warning).**
  We do not reserve 2⁶⁴ bytes. The paged backend grows on demand (sparse-friendly), a 64-bit memory
  with a small footprint just works, and an access/`grow` beyond the documented cap **traps / fails
  exactly where the spec expects**. `atomics`/`nif` keep their 32-bit reserve model and **fail closed**
  for a genuinely-huge 64-bit memory (no silent fallback). The exact cap is pinned against the spec by
  the scoping unit — a real constant with a spec citation, never a guess.
- **Cross-module linking is function + state linking across instances, scoped to the *measured*
  residual (I5, R16).** The skipcount currently labels ~1088 asserts ambiguously
  ("imported-global/ref.func element-init") while the Phase-5 capstone prose calls the residual
  "cross-module wasm→wasm function imports" — the conformance unit **audits exactly what those asserts
  are at the pin before scoping to close them**, and reports the measured drop, never a promised one.
- **This is a surface + finishing phase, not a speed phase.** Phase 4's benchmark numbers stand;
  Phase 6 adds no optimizer passes and makes no new performance claim. The one performance-shaped
  obligation is **negative**: the new ops preserve constant-space loops + preemption and do not
  regress the existing corpus.
- **The IR grows — deliberately and neutrally (I7).** Phase 6 adds `TV128`, a `ConstV128` value, the
  SIMD `Expr` node(s) + `SimdOp` enum, and a `.ir` grammar delta. Every addition is chosen
  **language-neutrally** (a generic 128-bit fixed-width value + generic lane ops, not WASM opcodes)
  and is **conformance-neutral by default**.
- **Deferred (state it):** relaxed-SIMD (the separate, non-deterministic proposal) → later; the
  **Porffor JS→WASM bridge → Phase 7** (now *unblocked* — the surface is complete after Phase 6); the
  Erlang/Gleam frontend; exception-handling / GC (incl. GC-proposal reftypes) / stack-switching / the
  component model; the single-`.beam` runtime-dispatch **B1** binding; tier-N numerics; a production
  C NIF for tier-N memory or tier-N SIMD; the **memory optimizer** (its own perf phase —
  [`future-work-memory-optimizer.md`](../future-work-memory-optimizer.md)). **WASI** stays an
  `rt_host` impl, out of core.

---

## 2. The Phase-6 decisions (I1–I8)

Frozen for Phase 6. If you believe one is wrong, raise it with the planner **before** building.

### I1 — The keystone is the `v128` value + the SIMD op layer (with the mem64 unfreeze + the cross-module import model riding along)

Phase 6's load-bearing new thing — the analogue of Phase-2's `cell`, Phase-4's `state_strategy`,
Phase-5's reference value model — is the **`v128` value type and its SIMD operation layer**. `v128`
is a **low-level fixed-width value** (high-level decision #4's *numeric* path, NOT the term layer),
represented at runtime as a **16-byte binary** (`<<_:128>>`) — the natural BEAM fixed-width byte
container, consistent with how linear-memory bytes are already handled, since the BEAM has no
128-bit scalar. A `ConstV128(bytes)` Value holds the exact 16 raw little-endian bytes (D5-style: the
bits, never a decoded structure — so lane values, NaN payloads, and `-0.0` are exact).

The keystone (**P6-01**) freezes: the new **`ValType` `TV128`**; the **`ConstV128` Value**; the SIMD
`Expr` node(s) + the **`SimdOp` enum** (I2); the **`rt_simd`** module signatures (doc-frozen,
`todo`-free — the ~236 op heads); the **memory64 runtime axis** (`lower`/`link` stop rejecting
`Idx64`; the **documented page cap** as a `Binding` field — I4); the **cross-module `ProvidedFunc`
dispatch model** (a linker-built closure capability — I5); the **`.ir` grammar delta** (I7); and any
new `TrapReason` (expected: **none** — SIMD is total, SIMD memory + memory64 reuse `MemoryOutOfBounds`,
unlinkable is a link-time error not a runtime trap). It **lands green** with defaults chosen so every
prior module is byte-identical.

### I2 — SIMD is a compact IR op-enum routed to `rt_simd`, mirroring `NumOp`→`rt_num` (NOT ~236 IR nodes)

Just as the ~90 `rt_num` functions hide behind the small `NumOp`/`ConvOp` enums carried by
`Num`/`Convert`, the ~236 SIMD instructions hide behind a **`SimdOp` enum** carried by a **few**
`Expr` nodes. Proposed shape (the scoping fan-out finalizes exact node/enum boundaries):

- **`Simd(op: SimdOp, args: List(Value))`** — the pure lane-wise ops (unary/binary/ternary: e.g.
  `i32x4.add`, `f64x2.sqrt`, `v128.bitselect`, `i8x16.eq`, splat, `any_true`/`all_true`, `bitmask`,
  narrow/widen/extend/convert/trunc_sat/dot). `SimdOp` is **width-and-lane-tagged and neutral** (never
  a WASM opcode string) — the same discipline as `NumOp` (D6).
- **Lane immediates** ride as fields on dedicated variants where they are static immediates:
  `ExtractLane`/`ReplaceLane` carry a lane index; **`i8x16.shuffle` carries its 16 lane indices**
  (a `Simd` variant or a dedicated `SimdShuffle(lanes, a, b)` node — scoping picks).
- **SIMD memory ops** (`v128.load/store` + the splat/extend/zero/lane families) route through the
  **existing `rt_mem` seam**, either as extended `MemLoad`/`MemStore` access kinds or as dedicated
  `SimdLoad`/`SimdStore`/`SimdLoadLane`/`SimdStoreLane` nodes — **scoping decides** (flagged §3), but
  the invariant is fixed: they are **bounds-checked through `rt_mem`**, never a raw term op (I6/D3a).

This keeps the IR compact and language-neutral (a future vector-capable frontend reuses `v128` +
`SimdOp`) and confines the ~236-way explosion to **`rt_simd`** (`emit_core` maps each `SimdOp`
constructor to an `rt_simd` function — the binding chokepoint, exactly like `NumOp`→`rt_num`). `v128`
is the **low-level path**: no implicit bridging to terms (a `Convert` boxing op is the only bridge, as
for i32/i64).

### I3 — SIMD semantics are bit-exact, emulated lane-wise, faithful-over-fast

`rt_simd` (tier-P `bif`, a new runtime module the shape of `rt_num`) implements each op by:
**decode** the 16-byte operand binary(ies) into lanes via bit-syntax (`<<a:32/little, b:32/little,
…>>`), **apply** the per-lane operation **reusing `rt_num`'s exact scalar semantics** (the same
two's-complement masking, shift-count masking mod lane-width, **f32 single-rounding**, IEEE-754
behaviour, **NaN propagation/canonicalization** — §9.1), **re-encode** the result lanes into a
16-byte binary. Consequences held to the spec, not the implementation:
- **Integer lanes wrap two's-complement at the *lane* width** (`i8`/`i16`/`i32`/`i64`), not 128-bit;
  shift counts are masked mod the lane bit-width; signed/unsigned min/max/compare/narrow per lane.
- **Saturating ops saturate exactly** (`narrow_*_s/u`, `i16x8.q15mulr_sat_s`, `trunc_sat`); no trap.
- **Float lanes are IEEE-754** with **f32x4 rounded to single precision after every op**, `min`/`max`
  returning the spec's NaN/`-0.0` result, `pmin`/`pmax` the pseudo-min/max variants, and NaN
  **canonicalization/propagation per the SIMD spec** (which mirrors scalar). `f32x4`/`f64x2`
  conversions (`convert_i32x4_s/u`, `demote`/`promote`, `trunc_sat`) are exact.
- **SIMD ops do not trap** (there is no SIMD division-trap; saturation replaces overflow-trap). The
  only trap on the SIMD surface is the **memory-bounds trap on a SIMD load/store**, via the existing
  bounds-checked `rt_mem` path.

This is **faithful, not fast** — there is no vectorization and **none is claimed** (I8). It is the
same posture as tier-P `bif` numerics: the honest, runs-anywhere, spec-exact implementation; a real
hardware-SIMD tier-N NIF is deferred.

### I4 — memory64's runtime lands, with a documented spec-aligned page cap (R12's deferred half)

P5 shipped **decode + validate** for memory64 and made `lower`/`link` **reject** `Idx64`
(`Memory64Unsupported`). Phase 6 removes the rejection and makes a 64-bit memory **run**:
- **`lower` accepts `Idx64`**; the memory-index/address plumbing carries the address width; `emit_core`
  threads **i64 address + i64 bounds arithmetic** through the memory seam for a 64-bit memory (a 32-bit
  memory is **unchanged / byte-identical**). `memory.size`/`memory.grow` on a 64-bit memory take/return
  **i64** page counts.
- **The page cap is the load-bearing honesty point.** We do **not** allocate 2⁶⁴ bytes. A **documented
  implementation limit** (the scoping unit pins the exact constant **against the WebAssembly memory64
  spec + a real engine's behaviour**, with a citation — never a guess) bounds a 64-bit memory; `grow`
  beyond it returns `-1`, an access beyond the *current* size **traps `MemoryOutOfBounds`** exactly as
  the spec's `assert_trap` expects. The `paged` backend already grows on demand, so the cap is a
  *trap boundary*, not a reservation.
- **`atomics`/`nif` keep their 32-bit reserve model and fail closed** for a 64-bit memory whose
  effective size exceeds the reserve (no silent fallback — the existing atomics fail-closed gate).
  memory64 therefore ships on **`paged` (+ `portable`)**; the tier matrix categorizes an over-cap
  64-bit atomics binding honestly, as prior phases categorized their tier edges.
- Every access stays **bounds-checked → trap** (I6): the worst case of a 64-bit bounds bug is a
  wrong/missing trap or a node-safe crash, **never a host escape**.

### I5 — Cross-module linking dispatches imported functions across instances via a build-constructed closure capability

P5 wired imported **state** (globals/tables/memories) + the `spectest` module, and `link.gleam`
already **matches** `ProvidedFunc(ty)` signatures — but there is **no cross-instance function
dispatch**: generated code cannot *call* an imported function that lives in another module's instance.
Phase 6 closes this:
- **A `ProvidedFunc` carries a build-constructed closure** — a first-class `fun` value the **linker**
  builds, capturing the target instance + the exported function (e.g. `fun(Args) -> a_instance:f(Args)
  end`, or the threaded-state analogue). The generated caller lowers an imported-function call to
  **`apply(Closure, Args)` over the handed-in closure** — a **capability**, exactly like `externref`
  and `call_host`, **NOT** an ambient `apply` of an attacker-chosen `module:atom` (D3a holds; the
  closure is supplied explicitly at link time, never looked up by an attacker-controlled name in
  generated code).
- **`link_imports` extends to functions**: an unsatisfied or signature-mismatched function import is a
  **link-time failure** (`assert_unlinkable`), fail-closed (I6/H6). The `(register "name" $mod)`
  mechanism (P5-10b's `Script` already parses it; the multi-module registry is the substrate) makes a
  prior module's exports importable by a later one.
- **State-strategy interaction is a scoping question (flagged §3).** Cross-instance calls compose
  cleanly under **`cell`** (each instance owns its pdict/process state). Under **`threaded`**, calling
  into instance B means running B's functions against B's state record — the honest first target is
  **`cell` (Safe default) for `linking.wast`**, with the `threaded`/matrix interaction of cross-module
  calls **categorized honestly** if it proves invasive (as P5 categorized spectest-memory-under-atomics).
  Lighting up `linking.wast` under one profile is a real conformance win; the scoping/reconciliation
  step decides how far the tier matrix extends.

### I6 — Security & fail-closed for the new surface

- **SIMD ops are pure/total** (no traps); their **only** trap surface is the SIMD memory load/store,
  which routes through the **existing bounds-checked `rt_mem` seam** → trap `MemoryOutOfBounds` before
  any partial effect. `v128` is an opaque 16-byte value in Safe mode — it cannot address memory except
  through the checked seam. Worst case of a SIMD bug is a wrong result or node-safe crash, never escape.
- **memory64 keeps every access bounds-checked → trap**; the page cap is a hard trap boundary; **Safe
  forbids tier-N** as before.
- **Cross-module function imports are fail-closed capabilities.** An unsatisfied/mismatched import
  fails at **link time**; the dispatch is a **handed-in closure** (no ambient authority — D3a
  grep-verified in P6-06's extended security test); a Safe instance importing an Unsafe instance's
  function is governed by the existing **per-instance policy** (the callee runs under its own linked
  runtime — the instance is the unit of policy, §13).
- **The `rebuild` oracle + the `wasmtime` differential hold every new op to the spec** (§11).

### I7 — The IR grows, but stays language-neutral & conformance-neutral by default

Phase 6 **does** add `TV128`, `ConstV128`, the SIMD `Expr` node(s) + `SimdOp` enum, and a **`.ir`
grammar delta** (owned + reconciled by P6-02, like the IR2/IR3 deltas). The anti-WASM-ism discipline
(high-level decision #1) holds:
- `v128` is a **generic 128-bit fixed-width value** (a future SIMD-capable frontend reuses it), not a
  WASM-only construct; SIMD ops are **generic lane operations** over it, not WASM opcode strings (D6).
- memory64 is the **generic `IdxType` axis already in the IR** (no new IR shape — just its runtime).
- Cross-module imports are **generic provided-function capabilities** (the `Provided`/`link` contract
  generalizes, no WASM immediate leaks into the IR).
- **Defaults are conformance-neutral:** a module with no SIMD, a single 32-bit memory, and no
  cross-module imports compiles **byte-identically** to Phase-5 under both modes and every shipped
  memory tier + state strategy. The prior corpus + suite stay green.

### I8 — Honest scope

See §1. Included: **SIMD** (`v128` + the ~236 standardized lane ops), the **memory64 runtime**,
**cross-module function linking**. **Emulated SIMD only** — no hardware vectorization, no speed claim.
memory64 uses a **documented, spec-aligned page cap**, not 2⁶⁴ allocation. Cross-module linking is
function/state linking across instances, scoped to the **measured** residual. **Deferred (each
stated):** relaxed-SIMD → later; the **Porffor JS→WASM bridge → Phase 7** (unblocked by Phase 6); the
Erlang/Gleam frontend; EH / GC / stack-switching / the component model; the single-`.beam` B1 binding;
tier-N numerics/SIMD; a production C NIF; the memory optimizer (its own phase). This is a surface
phase — the obligation is **conformance-neutral by default** + the new surface **differentially
spec-correct** under the full mode/tier matrix it is defined for. The performance story is Phase 4's,
unchanged. Do not claim hardware SIMD, a 2⁶⁴ memory, or greenness that is not **measured**.

---

## 3. Dependency DAG — freeze milestones

```
WAVE 0   01 KEYSTONE (one owner; lands green):
            «IR4-FROZEN»    (TV128 ValType + ConstV128 Value + SimdOp enum + SIMD Expr node(s) +
                             the SIMD-memory node decision + .ir grammar delta; no new TrapReason)
            «RT-SIMD-SIG»    (rt_simd.gleam signatures — the ~236 op heads, doc-frozen, todo-free)
            «MEM64-RUNTIME»  (Binding page-cap field + lower/link accept Idx64 contract)
            «XLINK»          (cross-module ProvidedFunc closure-dispatch contract + link/emit seam)
                 │
   ┌──────┬──────┬──────┬──────┬──────┬───────────┬───────────┬──────────────┐
   ▼IR4   ▼AST4  ▼AST4  ▼IR4   ▼IR4   ▼RT-SIMD     ▼MEM64       ▼XLINK
 ┌─────┐┌─────┐┌─────┐┌─────┐┌─────┐┌───────────┐┌───────────┐┌──────────────┐
 │02   ││03   ││04   ││05   ││06   ││07 rt_simd  ││08 rt_mem   ││09 cross-mod  │
 │.ir  ││decode││valid ││lower ││emit ││(3 passes: ││ memory64   ││ func linking │
 │text ││(+AST4)││ate  ││     ││core ││ 07a int    ││ runtime +  ││ (registry +  │
 │     ││      ││     ││     ││     ││ 07b float  ││ page cap   ││ closure disp)││
 │     ││      ││     ││     ││     ││ 07c misc/  ││            ││              ││
 │     ││      ││     ││     ││     ││ mem/shuf)  ││            ││              ││
 └─────┘└─────┘└─────┘└─────┘└─────┘└───────────┘└───────────┘└──────────────┘
  WAVE A  WAVE A WAVE A WAVE A WAVE A  WAVE A        WAVE A        WAVE A
                       ┌────────────────┐   ┌──────────────────────────────────┐
                       │10 conformance   │   │11 CAPSTONE: full standard green; │
                       │  expansion +    │   │   skip-count drops; fail=0 under │
                       │  residual audit │   │   the matrix; honest close;      │
                       │  + differential │   │   Phase 7 (Porffor) unblocked    │
                       └────────────────┘   └──────────────────────────────────┘
                            WAVE B                        WAVE C
```

- **Two critical paths.** (1) The **SIMD frontend pipeline** 03 decode → 04 validate → 05 lower is the
  broadest surface change (the `0xFD` prefix + ~236 sub-opcodes) and must move first behind `«AST4»`.
  (2) The **`emit_core` extension (06)** + **`rt_simd` (07)** are the deepest codegen + the largest
  runtime; 06 needs `«IR4»` + `«RT-SIMD-SIG»` (not the bodies), so it parallels 07. Start 03, 06, 07.
- **`rt_simd` (07) is the giant** — ~236 ops. It implements in **three sequential passes** (like the
  WAT parser's 10a/10b, R15): **07a** integer-lane ops, **07b** float-lane ops + conversions/
  narrowing/widening, **07c** shuffle/swizzle/lane-access/boolean-reductions/dot/**the v128 memory
  family**. Each pass differential-tested against `wasmtime`/the oracle.
- **memory64 (08)** and **cross-module linking (09)** are contained, mostly-independent tracks; 08
  needs `«MEM64-RUNTIME»`, 09 needs `«XLINK»` + the P5 `link.gleam`/registry substrate.
- **Conformance (10)** needs the whole pipeline + runtime and **owns the empirical residual audit**
  (R16); **the capstone (11)** proves the phase and unblocks Phase 7.

*(Proposed unit split — the scoping agents may refine, as in every prior phase. Open scoping questions
they must resolve: **(a)** the exact SIMD `Expr` node/enum boundary and whether SIMD memory ops extend
`MemLoad`/`MemStore` or get dedicated nodes; **(b)** whether 07 is truly 3 passes or needs a finer
split; **(c)** the exact memory64 page cap constant + its spec citation; **(d)** how far cross-module
linking extends across the `state_strategy × mem_tier` matrix vs an honest categorized edge; **(e)**
the empirical composition of the ~1088-assert residual at the pin.)*

---

## 4. File-ownership map (D1)

> Single owner per file. Several units **extend** existing files (single-owner, additive). The
> keystone makes deliberate, documented cross-file reaches (growing `ValType`/`Value`/`Expr` breaks
> every exhaustive match — it must land green).

| Unit | File(s) | Notes |
|---|---|---|
| **01** keystone | `ir.gleam` (`TV128`, `ConstV128`, SIMD `Expr` node(s) + `SimdOp` enum, the SIMD-memory node decision) · **`runtime/rt_simd.gleam` (NEW — the ~236 op signatures, doc-frozen todo-free)** · `runtime/instance.gleam` *(memory64 page-cap `Binding` field)* · `runtime/link.gleam` *(cross-module `ProvidedFunc` closure-dispatch contract head)* · `ir/effect.gleam` *(classify SIMD nodes — pure lanewise are pure; SIMD memory are barriers)* · `ir/printer.gleam`/`ir/parser.gleam`/`backend/emit_core.gleam`/`frontend/wasm/lower.gleam` *(minimal compile-satisfying arms; full impls are 02/05/06)* | `«IR4-FROZEN»`/`«RT-SIMD-SIG»`/`«MEM64-RUNTIME»`/`«XLINK»`. Land green, byte-identical defaults. |
| **02** `.ir` textual | `ir/printer.gleam`, `ir/parser.gleam` (extend) + `specs/phase-6/ir-grammar-delta.md` | Full round-trip of `v128.const` (16-byte hex) + every `SimdOp` + memory64 forms + cross-module import forms; legacy modules print byte-identically. |
| **03** decode ext | `frontend/wasm/decode.gleam`, `frontend/wasm/ast.gleam` (extend) | Publishes **`«WASM-AST4»`** day 1: the `0xFD` SIMD prefix + all ~236 sub-opcodes, `v128.const` (16 immediate bytes), the shuffle/lane immediates, the v128 memory instructions + their memarg + lane immediates. |
| **04** validate ext | `frontend/wasm/validate.gleam` (extend) | SIMD typing (`v128` on the abstract stack; lane-index immediates in range; shuffle indices 0..31); memory64 `i64`-address typing (mostly P5 — confirm); cross-module function-import typing. Security boundary; rejects ill-typed fail-closed. |
| **05** lower ext | `frontend/wasm/lower.gleam` (extend) | WASM AST4 → IR4 for every SIMD op; **memory64: accept `Idx64` (stop rejecting), thread the i64 address width**; cross-module function imports → IR call shape. |
| **06** emit_core ext | `backend/emit_core.gleam` (extend) | Lower all SIMD nodes through the `rt_simd` seam (`SimdOp`→`rt_simd` fn, the binding chokepoint); memory64 i64 addressing through the mem seam; **cross-module imported-function call → `apply(Closure, Args)`**; extend the D3a security-invariant test (SIMD + the closure-dispatch no-ambient-authority proof). Deepest codegen change. |
| **07** rt_simd | **`runtime/rt_simd.gleam` (NEW, extend across 07a/07b/07c)** — **does NOT edit `rt_num.gleam`; consumes it** | The ~236 lane ops over the 16-byte binary, bit-exact, reusing `rt_num` per lane; the v128 memory family through `rt_mem`; differential vs `wasmtime`/oracle. Three sequential passes (int / float+convert / misc+mem+shuffle). |
| **08** rt_mem memory64 | `runtime/rt_mem.gleam` (extend) + `rt_mem_atomics`/`rt_mem_nif` *(fail-closed gate for over-cap 64-bit)* | i64 addressing + 64-bit bounds + the **documented page cap** (spec-cited); paged (+ portable); atomics/nif fail closed for over-cap mem64; differential vs oracle; 32-bit heads byte-identical. |
| **09** cross-module linking | `runtime/link.gleam` (extend: `ProvidedFunc` closure dispatch + function `link_imports`), `runtime/profiles.gleam`/`pipeline.gleam`, the multi-instance registry glue | The linker-built closure capability; fail-closed function-import matching; `(register …)` end-to-end; D3a-clean (no ambient `apply`). 06 emits the `apply(Closure,…)`; 10 drives `linking.wast`. |
| **10** conformance expansion | `test/twocore/conformance/**` (extend) | Light up `simd/*.wast`, `memory64.wast`, `linking.wast`; **empirical `wast2json`-convertibility + residual audit at the pin (R16)**; report measured pass/skip/fail honestly; differential vs `wasmtime`. |
| **11** capstone | `test/twocore/conformance/**`, `test/**`, `docs/` | Full standard green under the matrix; skip-count-drop headline; conformance-neutral proof; SVG refresh; honest close; **Phase 7 (Porffor) explicitly unblocked**. |

*(Known seams to pin in reconciliation, flagged so nothing is double-owned: the **SIMD-memory node**
boundary between 01/03/06/07; **`rt_num` reuse** by `rt_simd` (07 consumes, never edits `rt_num`); the
**memory64 page-cap constant** owner (08 picks, 01 freezes the `Binding` field); the **cross-module
closure dispatch** seam between 01/06/09 and its `state_strategy` reach.)*

---

## 5. How to claim & complete (same as Phases 1–5)

Read this page → `RECONCILIATION.md` → your unit doc → [`specs/state.md`](../state.md). Set status
`in-progress`; confirm your freeze milestones; build to the Definition of Done (D8: **spec-cited**
tests written against the [WebAssembly spec](https://webassembly.github.io/spec/) — for SIMD the
[fixed-width SIMD spec](https://webassembly.github.io/spec/core/) / the `simd/*.wast` suite — doc
comments on every public function, `gleam format --check src test` clean, **zero warnings**, and your
unit's conformance/interface suite passing — "done" is *the suite passes*, never "it compiles").
Update `state.md` with what you leave. When in doubt about a foundational decision, **ask the
planner**. The manager QA-gates (`format`/`build`/`test` + conformance `fail=0` + a spec-DoD read) and
commits+pushes each unit to `main`.

---

## 6. Deferred to Phase 7+ (explicit — stated, not dropped)

- **Phase 7 — "JS on the BEAM" via Porffor (now unblocked):** with the WASM surface **complete** after
  Phase 6, *any Porffor application runs via 2core on the BEAM* becomes buildable. Porffor's JS→WASM
  output is runnable through `fe_wasm`; the work is a **Porffor-ABI `rt_host` shim** (Porffor's own
  runtime ABI — its console/memory/string/intrinsic imports, not WASI) + a JS-subset conformance
  harness. This is Phase 7.
- **Later:** relaxed-SIMD (the non-deterministic proposal); the Erlang/Gleam frontend; exception-
  handling, GC (incl. the GC proposal's typed function references + `struct`/`array`/`i31`),
  stack-switching, the component model; the single-`.beam` runtime-dispatch **B1** binding; tier-N
  numerics; a production **C NIF** for tier-N memory *or* real hardware **tier-N SIMD**; the **memory
  optimizer** (its own performance phase — MemorySSA + alias analysis + BCE + LICM + store→load
  forwarding + DSE). **WASI** stays an `rt_host` implementation, out of core.
```
