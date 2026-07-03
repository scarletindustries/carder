# Unit P7-07 — `rt_exn` (the tagged-exception runtime over BEAM-native exceptions)

> **One owner · Wave A (parallel with 02/03/04/05/06/08) · gated on `«EH-IR-FROZEN»`
> + `«RT-EXN-SIG»` (keystone P7-01).**
> Read [`00-overview.md`](00-overview.md) (J1–J8), [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md),
> the Phase-6 reconciliation [`../phase-6/RECONCILIATION.md`](../phase-6/RECONCILIATION.md) (S8 —
> `TrapReason` discipline — still holds), and the template unit
> [`../phase-6/07-rt-simd.md`](../phase-6/07-rt-simd.md) first. You create **one new runtime module** —
> `runtime/rt_exn.gleam` (+ a small `twocore_rt_exn_ffi.erl` shim, and a *conditional, minimal*
> `rt_trap.gleam` touch) — the tier-P reference implementation of 2core's **tagged structured-exception
> runtime**, lowered directly onto **BEAM-native exceptions** (Core Erlang `try … catch`,
> `erlang:throw`, `erlang:raise/3`). Your load-bearing constraints: the thrown term is a **build-fixed
> shape** `{wasm_exn, TagId, Payload}` — **no ambient authority, no attacker-chosen `apply`** (D3a); a
> caught `exnref` is **forge-proof and opaque** exactly as `externref` is (reuse `rt_ref`'s box model,
> R1); a `try_table` catch **matches the tag, binds the payload, and faithfully RE-RAISES a non-matching
> exception** (class + reason + stacktrace preserved — spec §4.4.9 unwinding); **traps are NOT caught**
> (a trap inside a `try` propagates out — EH is orthogonal to traps); and **constant-space loops +
> preemption survive** a throw (BEAM unwinding is native, fuel still bites). `rt_exn` is a **pure term
> module** — no memory, no NIF, cannot crash the node.

---

## Context

Phases 1–6 shipped the complete WebAssembly **2.0** engine on the BEAM. Phase 7's single load-bearing
new engine feature (J1) is **exception handling**, because it is the *only* WASM feature real Porffor
output uses that Phase 6 does not already run (measured — [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md):
"64× throw in a trivial program"). The BEAM has first-class exceptions, so — exactly like tail-calls →
BEAM tail-calls and preemption → the scheduler — WASM EH lowers *directly* onto the BEAM's native
`throw`/`error`/`try…catch`/`raise` machinery. There is **no interpreter and no reified stack**: a WASM
`throw` becomes a BEAM `throw`, a `try_table`/`catch` becomes a BEAM `try … catch`, and a non-matching
exception is re-raised by the BEAM's own `erlang:raise/3` (which preserves the original class + reason +
stacktrace). This is the compile-to-Erlang payoff at its cleanest.

The runtime is split, like every other layer, across a **neutral IR surface** (J2 — `Module.tags` +
`Throw`/`TryTable`/`ThrowRef` `Expr` + an `exnref` reference value, frozen by the keystone P7-01), a
**backend chokepoint** (`emit_core`, P7-06 — the EH IR nodes → Core Erlang `try/catch/throw/raise`),
and **this runtime module** (`rt_exn` — the *term shape* and the small set of primitives the emitted
`try` composes). `rt_exn` is the **binding chokepoint for the exception term**: the shape
`{wasm_exn, TagId, Payload}` and the forge-proof `exnref` box live in **exactly one place** (this
module + its FFI shim), never smeared across emitted Core Erlang — precisely as `rt_trap` owns the
`{wasm_trap, Kind}` shape and `rt_ref` owns the reference-value tuples. This unit is the analogue of
P6-07 (`rt_simd`) one axis over: where `rt_simd` is a **pure value** module (lanes over a binary),
`rt_exn` is a **pure term** module (the exception term + its forge-proof reference handle) — both
tier-P, both `Result`-free on their hot path (a `throw`/`match`/`reraise` cannot itself fail), both
reused-not-reinvented (`rt_exn` reuses `rt_ref`'s box discipline and `rt_trap`'s raise channel).

**Conformance-neutral by default (J6).** A module with **no tags** references **no** `Throw`/`TryTable`/
`ThrowRef` node and links **no** `rt_exn` — so the entire Phase-1..6 corpus decodes/validates/lowers/
emits **byte-identically** (there is no Phase-6 `rt_exn` to differ from; the neutrality is automatic,
like `rt_simd`'s was).

---

## Goal

Create `runtime/rt_exn.gleam` (+ `twocore_rt_exn_ffi.erl`) — the tier-P, `todo`-free reference
implementation of the tagged-exception runtime — implementing, behind the keystone-frozen public heads
(`«RT-EXN-SIG»`, §B):

- **`throw_exn(tag_id, payload)`** — construct the **build-fixed** exception term
  `{wasm_exn, TagId, Payload}` and **raise it** (`erlang:throw` — *throw* class, so it is cleanly
  distinct from a `{wasm_trap, _}` *error*-class trap). Never returns (bottom). This is what a
  `Throw(tag, args)` IR node lowers to (via `emit_core`). D3a: the shape is baked; the payload is data,
  never an `apply` target.
- **`match_tag(reason, tag_id)`** — the **catch-clause** helper the emitted `try` uses per `catch <tag>`/
  `catch_ref <tag>` clause: `Ok(payload)` iff the caught term is a `{wasm_exn, tag_id, payload}`, else
  `Error(Nil)` (a *different* tag, a `{wasm_trap, _}` trap, or any other BEAM term). Total.
- **`is_wasm_exn(reason)`** — the **`catch_all`** helper: `True` iff the caught term is **any**
  `{wasm_exn, _, _}` — so a trap / BEAM error / exit is **not** swallowed by `catch_all` (spec: `catch_all`
  catches exceptions, **never traps**). Total.
- **`reraise(class, reason, stacktrace)`** — **faithfully re-raise** a non-matching caught exception via
  `erlang:raise/3`, preserving the original **class + reason + stacktrace** (spec §4.4.9: an unmatched
  exception propagates unchanged to the next outer handler). Never returns.
- **`capture_exnref(reason)`** — capture a caught exception as an **opaque, forge-proof `exnref`** handle
  `{ref_exn, {wasm_exn, TagId, Payload}}` (reuse `rt_ref`'s box discipline, R1) — for the `catch_ref`/
  `catch_all_ref` clause variants (modern proposal) and the legacy `rethrow`'s captured-exception
  semantics. Opaque: Safe code may hold/pass/store/re-throw it but **cannot read** `TagId`/`Payload`.
- **`throw_ref(exnref)`** — re-throw a caught `exnref` (the `throw_ref` op / legacy `rethrow`): unbox and
  re-raise the captured `{wasm_exn, …}` identically; a **null `exnref` TRAPS** (spec: `throw_ref` on
  null → trap). Never returns.
- **`is_exnref(x)`** — a structural `{ref_exn, _}` test for the reference-value classifier (the harness's
  reference-return judgement + defensive checks), mirroring `rt_ref.is_extern`.

Held to the **WebAssembly exception-handling proposal**
(<https://github.com/WebAssembly/exception-handling> + the core-spec integration: the tag section §5.5,
the control-instruction exec §4.4.9, the typing §3.4) via **spec-cited property tests** (throw/catch
round-trip, non-matching re-raise, `catch_all`, nested try/catch, `exnref` re-throw), a **D3a
grep-backed no-ambient-authority proof**, and **conformance readiness** for the EH `.wast` corpus
(`throw.wast` / `try_catch.wast` / `tag.wast` / `throw_ref.wast` where in scope, P7-09/P7-10) — and it is
**byte-identical for tag-free modules** (no tag ⇒ no `rt_exn`).

---

## Files owned

| File | Status |
|---|---|
| `src/twocore/runtime/rt_exn.gleam` | **NEW (single owner).** The frozen public heads (§B) over the build-fixed exception term + the forge-proof `exnref`. `todo`-free. **Imports `rt_ref`** (null test, R1) **and `rt_trap`** (the null-`throw_ref` trap channel); **never edits either** (D1). |
| `src/twocore_rt_exn_ffi.erl` | **NEW (single owner).** The hand-written Erlang tuple shim — construct/pattern-match `{wasm_exn, TagId, Payload}` and the `{ref_exn, _}` box, `erlang:throw`, `erlang:raise/3` — that Gleam's `dynamic` API cannot express ergonomically. Namespace-prefixed (`twocore_`), pure term construction/matching: no NIF, no process state, cannot crash the node. Exact analogue of `twocore_rt_ref_ffi.erl`. |
| `src/twocore/runtime/rt_trap.gleam` | **EXTEND — conditional & minimal (§G).** The *only* possible touch is **one** new `spec_trap_message`/`trap_reason_atom` arm **iff** the keystone adds a `TrapReason` for `throw_ref`-on-null (spec: null → trap). Recommend **deferring** per S8 discipline — see §G / Open questions #2. If no variant is added, `rt_trap` is **untouched**. |
| `test/twocore/runtime/rt_exn_test.gleam` *(new)* | Spec-cited suite: throw/catch round-trip, non-matching re-raise (faithful class/reason/trace), `catch_all` (catches any exn, never a trap), nested try/catch unwinding, `exnref` capture + `throw_ref` re-throw, null-`throw_ref` trap, forge-proofness (opacity), and the D3a grep proof. |

**You do NOT own** (describe the seam, do not claim — D1): `ir.gleam` (keystone P7-01 — `Module.tags`/
`TagDecl`, the `Throw`/`TryTable`/`ThrowRef` `Expr` nodes, the `exnref`/`TExnRef` value, and the
`TrapReason` set; §A pins the shapes this unit consumes), `runtime/rt_ref.gleam` (**consumed, never
edited** — the null sentinel + the box discipline), `backend/emit_core.gleam` (P7-06 — the EH-node →
Core Erlang `try/catch/throw/raise` composition + the D3a test extension; §C describes it), `ir/
effect.gleam` (keystone — classifies the EH nodes as **effectful barriers**), `frontend/wasm/decode.gleam`
+ `validate.gleam` + `lower.gleam` (P7-03/04/05 — the WASM EH surface → neutral IR), and the run-ABI/
harness (P7-08/09 — the **uncaught-exception outcome**, §F). Any shape this unit needs from the keystone
is pinned in §A/§B and flagged in Deviations / Open questions.

---

## Deliverables & freeze milestones

**Produces no freeze milestone** — this unit *consumes* `«EH-IR-FROZEN»` (the `TagDecl` +
`Throw`/`TryTable`/`ThrowRef` nodes + the `exnref` value) and `«RT-EXN-SIG»` (the keystone-frozen
`rt_exn` public heads — §B — so P7-06 emits against them while the bodies land here). Exactly the P6-07
relationship to `«RT-SIMD-SIG»`. It ships:

1. **The `rt_exn` bodies** (§B) — `throw_exn`, `match_tag`, `is_wasm_exn`, `reraise`, `capture_exnref`,
   `throw_ref`, `is_exnref` — total, `todo`-free, each with a `///` contract doc (D8).
2. **The `twocore_rt_exn_ffi.erl` shim** — the tuple construction/matching + `erlang:throw`/`raise/3`
   (§A.4), the forge-proof `{ref_exn, _}` box (§E).
3. **The spec-cited property suite + the D3a proof** (§Verification), readying the engine for the EH
   `.wast` corpus under P7-09/P7-10.
4. **(Conditional) the single `rt_trap` arm** for `throw_ref`-on-null, *only if* the keystone adds the
   reason (§G) — else `rt_trap` untouched.

---

## Depends on (freeze milestones)

- **`«EH-IR-FROZEN»` (P7-01)** — the shapes this unit's term must round-trip:
  - **`TagDecl`** — a tag = a name + a `FuncType`-style operand signature (the value types the exception
    carries) + its import/export state (P5 pattern). `rt_exn` never sees a `TagDecl`; it sees the
    **`tag_id: Int`** the build assigns (§A.3 — the tag's stable identity).
  - **`Throw(tag, args)`** `Expr` — bottom (does not return, like `Trap`/`Return`); lowers to
    `throw_exn(tag_id, [args…])`.
  - **`TryTable(result, body, catches)`** `Expr` — `body` evaluated; each `catch` clause is
    `(tag | catch_all, label, ref?: Bool)`; on a matching thrown tag transfer to `label` with the
    payload (+ the exnref if `ref`), else propagate. Structured (named labels, D6) → a Core Erlang `try`.
  - **`ThrowRef(exnref)`** `Expr` — bottom; lowers to `throw_ref(exnref)`.
  - **`exnref` / `TExnRef`** — a new reference-layer value (a caught-exception handle, opaque like
    `TExternRef`); the null exnref is the shared `rt_ref` null sentinel.
  - **`TrapReason` confirmation** — whether a `throw_ref`-on-null reason is added (§G). Default per S8:
    **no new variant** unless a pinned `.wast` needs it.
- **`«RT-EXN-SIG»` (P7-01)** — the keystone doc-freezes this unit's §B public heads (`todo` bodies) so
  P7-06 wires the EH-node → `rt_exn` composition immediately while the bodies land here. The composition
  **must** match these names/arities.
- **`rt_ref` (Phase-5 keystone R1, frozen & green)** — `rt_ref.null_ref()` / `rt_ref.is_null(x)` (the
  shared null sentinel `{ref_null}`) reused for the **null exnref** and the `throw_ref`-null test, and the
  **box discipline** (`{ref_extern, Term}`) copied one tag over for `{ref_exn, _}` (§E). Consumed, never
  edited (D1).
- **`rt_trap` (Phase-1..6, frozen & green)** — `rt_trap.raise(reason)` (the catchable `{wasm_trap, Kind}`
  error-class channel) reused as the target for the `throw_ref`-on-null **trap** (§G). Extended only
  conditionally (one arm) — never in its dispatch shape.

---

## A. The representation — a build-fixed exception term, an opaque exnref, reuse `rt_ref`/`rt_trap`

### A.1 The exception term (D3a — build-fixed, forge-proof by construction)

A WASM exception carrying tag `TagId` and operand values `Payload` is the **3-tuple**

```
{wasm_exn, TagId, Payload}
```

raised at **`throw` class** (`erlang:throw/1`). This mirrors `rt_trap`'s `{wasm_trap, Kind}` (2-tuple,
*error* class) and `rt_ref`'s tagged tuples exactly: **one fixed outer atom** (`wasm_exn`) so the term
is (a) **unambiguously a WASM exception** — distinct from a trap `{wasm_trap, _}`, a denial
`{capability_denied, _, _}`, and every reference tuple — and (b) **build-controlled**: the *only*
producer of a `{wasm_exn, …}` term is this module (`throw_exn` / `throw_ref`), reached *only* from a
`Throw`/`ThrowRef` IR node. **Safe WASM code cannot forge it** — WASM values are numbers, `v128`, and
references; no WASM operation constructs an arbitrary BEAM 3-tuple with the atom `wasm_exn` (the term
layer `TermOp` is a lock-now placeholder). This is the same forge-proof-by-construction argument that
makes `{ref_null}` unforgeable (R1). **D3a holds by inspection:** `throw_exn` builds a fixed-shape tuple
and hands `Payload` as *data*; it never derives a module/function atom from `TagId`/`Payload` and never
`apply`s anything — a thrown value is a term, **never authority** (J5).

- **`TagId`** — the tag's stable identity (an `Int`, §A.3).
- **`Payload`** — the tag's operand values, as a **`List`** (`List(Dynamic)`): each element is a WASM
  value — a raw-bit `Int` (numeric, D5), a 16-byte `BitArray` (`v128`), or a reference `Dynamic`. The
  list carrier is consistent with the R17 multi-value invoke ABI and the S5 `CallImport` closure ABI
  (`fn(List) -> List`). For Porffor the payload is exactly **two** values — the `(f64, i32)` typed-value
  pair (the thrown JS value + its type tag), so `Payload = [F64Bits, I32Tag]` (measured — the tag is
  `(param f64 i32)`).

### A.2 Why *throw* class (not *error*), and why the match is on the term shape

`erlang:throw/1` raises **throw**-class; `rt_trap` raises **error**-class (`erlang:error/1`). Choosing
**throw** for WASM exceptions gives two properties:

1. **Semantic aptness** — JS `throw` → BEAM `throw` (the natural mapping; the Porffor headline).
2. **Class-level distinctness** — a WASM exception (throw) and a WASM trap (error) are different
   *classes*, so the top-level runner can catch/report them on separate arms without ambiguity (§F).

But the *catch-side match is on the term shape, not the class* (`match_tag`/`is_wasm_exn` pattern-match
`{wasm_exn, …}`). This is the **robust, fail-closed** choice: the emitted `try` catches **all classes**
(`<Class, Reason, Stacktrace>`) and decides caught-vs-reraise by the term shape, so a stray non-WASM
`throw`/`error`/`exit` from any layer is **faithfully re-raised**, never mis-caught as a WASM exception.
Correctness therefore does **not** depend on the class choice — the class choice is only a
*distinctness/aptness* convenience. (This is exactly why `rt_trap` uses a fixed *outer tag* rather than
relying on class alone.)

### A.3 Tag identity (`TagId`) — generative, per the spec

WASM EH tags have **generative identity** (spec §4.5 tag instances): two *distinct* tag definitions
**never match**, even with identical operand signatures; an **imported** tag shares identity with the
tag it was matched against at instantiation. `rt_exn` reduces this to **`Int` equality on `TagId`**:
`match_tag(reason, tag_id)` matches iff the caught exception's `TagId` **equals** the clause's `tag_id`.
The generative guarantee is therefore the **build/linker's** job — a *cross-unit seam*:

- **Single module (the Porffor headline + most EH `.wast`):** `TagId` = the module-local **tag index**
  (Porffor's sole tag ⇒ `TagId = 0`). All throws/catches in one instance share the one tag table, so
  index equality *is* identity. This covers the entire measured corpus.
- **Cross-module (imported/exported tags — `tag.wast`):** the linker (P7-08) must assign **distinct**
  `TagId`s to distinct definitions and the **same** `TagId` to an imported tag and its export, so that
  index collisions across modules cannot alias two different tags. Flagged (Open questions #3). `rt_exn`
  is agnostic: it only requires *equal `TagId` ⟺ same tag*.

`TagId` is kept an `Int` (the simplest carrier that satisfies the corpus). If cross-module generativity
demands an opaque token (a `make_ref()`-style identity), the interface widens to
`throw_exn(tag_id: Dynamic, …)` / `match_tag(reason, tag_id: Dynamic)` with no body change (equality is
`=:=` either way) — but that is a keystone/linker call, flagged not pre-committed.

### A.4 The FFI shim (`twocore_rt_exn_ffi.erl`) — tuple construction/matching + native raise

Gleam's `dynamic` API cannot construct/destructure a fixed-atom tuple `{wasm_exn, …}` or call
`erlang:raise/3` with a runtime class atom ergonomically, so — exactly as `rt_ref` uses
`twocore_rt_ref_ffi.erl` — `rt_exn` delegates the term-level primitives to a tiny hand-written Erlang
shim (namespace-prefixed, pure, node-safe):

```erlang
%%% twocore_rt_exn_ffi — the build-fixed WASM-exception term shim for `rt_exn` (J1/J5).
%%% Pure term construction / pattern matching + native raise: no NIF, no process
%%% state, cannot crash the node. Namespace-prefixed (never collides with OTP).
-module(twocore_rt_exn_ffi).
-export([throw_exn/2, match_tag/2, is_wasm_exn/1, capture_exnref/1,
         reraise/3, rethrow_exnref/1, is_exnref/1]).

%% throw_exn(TagId, Payload) -> no_return()
%% Build the build-fixed exception term and raise it (THROW class — distinct from a
%% {wasm_trap,_} ERROR-class trap). D3a: fixed shape, Payload carried as data.
throw_exn(TagId, Payload) -> erlang:throw({wasm_exn, TagId, Payload}).

%% match_tag(Reason, TagId) -> {ok, Payload} | {error, nil}
%% The per-clause catch match: Ok iff Reason is a wasm exn of exactly TagId.
%% A different tag, a {wasm_trap,_} trap, or any other term -> {error, nil}.
match_tag({wasm_exn, TagId, Payload}, TagId) -> {ok, Payload};
match_tag(_, _) -> {error, nil}.

%% is_wasm_exn(Reason) -> boolean()   (the catch_all gate — never true for a trap)
is_wasm_exn({wasm_exn, _, _}) -> true;
is_wasm_exn(_) -> false.

%% capture_exnref({wasm_exn,_,_}) -> {ref_exn, {wasm_exn,_,_}}
%% Box a caught wasm exn as an opaque, forge-proof exnref (rt_ref box discipline).
%% Precondition: a wasm exn (guaranteed — only called after match_tag/is_wasm_exn).
capture_exnref({wasm_exn, _, _} = Exn) -> {ref_exn, Exn}.

%% reraise(Class, Reason, Stacktrace) -> no_return()
%% Faithfully re-raise a non-matching exception, preserving class/reason/stacktrace.
reraise(Class, Reason, Stacktrace) -> erlang:raise(Class, Reason, Stacktrace).

%% rethrow_exnref({ref_exn, Exn}) -> no_return()   (throw_ref of a NON-null exnref)
%% Re-throw the captured wasm exn identically (fresh throw, same {wasm_exn,_,_};
%% WASM has no observable stacktrace, so a fresh throw point is spec-faithful).
rethrow_exnref({ref_exn, Exn}) -> erlang:throw(Exn).

%% is_exnref(X) -> boolean()   (structural {ref_exn,_} test; opaque — no unwrap exported)
is_exnref({ref_exn, _}) -> true;
is_exnref(_) -> false.
```

`rt_exn.gleam` `@external`s each of these and adds the **null-`throw_ref` guard** in Gleam (so it can
route to `rt_trap` with a proper reason — §G) and the doc contracts. No `rt_exn` primitive returns a
`Result` on its hot path except `match_tag` (whose `{ok,_}`/`{error,_}` is the universal shape
`emit_core` already `case`s on everywhere).

---

## B. The frozen uniform interface (`«RT-EXN-SIG»`) — the seven heads

`emit_core` (P7-06) maps each EH IR node (and each `TryTable` catch clause) onto these heads. **All are
`pub`, carry a `///` contract doc (D8), and take/return raw terms** (`Dynamic` for a caught reason /
exnref, `Int` for `tag_id`, `List(Dynamic)` for a payload). The `throw*`/`reraise` heads are **bottom**
(never return — typed `-> a` so the emitter can place them in any value position, exactly like
`rt_trap.raise`). This §B is the head list the keystone freezes; any addition/rename this unit finds
necessary is flagged in Deviations.

```gleam
// ── the throw side ────────────────────────────────────────────────────────────
/// Throw a WASM exception of tag `tag_id` carrying `payload`. Raises {wasm_exn, TagId,
/// Payload} (throw class); NEVER returns. Lowered from a `Throw(tag, args)` node.
pub fn throw_exn(tag_id: Int, payload: List(Dynamic)) -> a

// ── the catch side (used by the emitted `try` per `TryTable` clause) ───────────
/// Per-clause match (`catch <tag>` / `catch_ref <tag>`): Ok(payload) iff `reason` is a
/// wasm exn of exactly `tag_id`; Error(Nil) for a different tag / a trap / any other term.
pub fn match_tag(reason: Dynamic, tag_id: Int) -> Result(List(Dynamic), Nil)

/// The `catch_all` / `catch_all_ref` gate: True iff `reason` is ANY {wasm_exn, _, _}.
/// False for a {wasm_trap,_} trap, a BEAM error, or an exit (they are NOT caught — spec).
pub fn is_wasm_exn(reason: Dynamic) -> Bool

/// Faithfully re-raise a non-matching caught exception, preserving class + reason +
/// stacktrace (spec §4.4.9 unwinding). NEVER returns. The terminal arm of every clause chain.
pub fn reraise(class: Dynamic, reason: Dynamic, stacktrace: Dynamic) -> a

// ── the exnref handle (forge-proof, opaque — §E) ──────────────────────────────
/// Capture a caught wasm exn as an opaque, forge-proof exnref (for `catch_ref`/
/// `catch_all_ref`, and the legacy `rethrow` captured-exception semantics).
/// Precondition: `reason` is a wasm exn (only called after a positive match).
pub fn capture_exnref(reason: Dynamic) -> Dynamic

/// Re-throw a caught exnref (`throw_ref` / legacy `rethrow`): re-raise the captured
/// {wasm_exn,_} identically. A NULL exnref TRAPS (spec: throw_ref on null → trap, §G).
/// NEVER returns.
pub fn throw_ref(exnref: Dynamic) -> a

/// Structural exnref test — {ref_exn, _} (opaque; no unwrap). For the reference-value
/// classifier (harness reference-return judgement + defensive checks). Mirrors rt_ref.is_extern.
pub fn is_exnref(x: Dynamic) -> Bool
```

Seven heads — the whole EH runtime surface. (Contrast `rt_simd`'s ~236: EH's explosion is in the
*frontend* surface — the tag section + `throw`/`try_table`/`throw_ref`/legacy `try`/`catch`/`catch_all`/
`delegate`/`rethrow` opcodes — all of which the neutral IR + `emit_core` collapse onto these seven
runtime primitives.)

---

## C. The BEAM-native lowering (the seam `emit_core` composes — P7-06 owns it)

`rt_exn` provides the primitives; **`emit_core` (P7-06) emits the Core Erlang `try`** that composes them.
Described here so the seam is agreed in one place (this unit's tests drive the same shapes). The mapping
is spec-faithful and *native* — no interpreter, constant-space, preemptible.

### C.1 `Throw(tag, args)` → `throw_exn`

```
Throw(tag, [a0, a1, …])   ⟶   call 'twocore@runtime@rt_exn':'throw_exn'(TagId, [A0, A1, …])
```

A bare tail call to `throw_exn`; `TagId` is the build-assigned literal (§A.3), the args are emitted as a
value list. Bottom — placed in any value position (like `raise_trap`). D3a-legible in `.ir`.

### C.2 `TryTable(result, body, catches)` → a Core Erlang `try … catch`

The load-bearing mapping (spec §4.4.9). The emitted shape, for clauses
`[catch t_a → L_a, catch_ref t_b → L_b, catch_all → L_c]` (illustrative; general form below):

```erlang
try  <Body>  of  Xs -> Xs
catch <Class, Reason, Stacktrace> ->
  case rt_exn:match_tag(Reason, T_a) of
    {ok, PayloadA} -> <bind PayloadA to L_a's operands; Break(L_a, PayloadA)>
    {error, _} ->
      case rt_exn:match_tag(Reason, T_b) of
        {ok, PayloadB} ->
          <bind PayloadB ++ [rt_exn:capture_exnref(Reason)] to L_b's operands; Break(L_b, …)>
        {error, _} ->
          case rt_exn:is_wasm_exn(Reason) of         %% catch_all
            true  -> <Break(L_c, [])>
            false -> rt_exn:reraise(Class, Reason, Stacktrace)
          end
      end
  end
```

Precise semantics, all spec-cited:

- **Clauses are tried in order; the first match wins** (spec: the handler list is searched in order). A
  nested `case`/`match_tag` chain realises this exactly.
- **`catch <tag> L`** — `match_tag(Reason, TagId)` → `{ok, Payload}` ⇒ **push the payload** and **branch
  to `L`** (an enclosing block label — the IR `Break(L, Payload)`; the payload becomes the branch
  operands, which validation P7-04 has typed against `L`).
- **`catch_ref <tag> L`** — same, but the branch operands are **`Payload ++ [capture_exnref(Reason)]`**
  (the exnref pushed *after* the values — spec order).
- **`catch_all L`** — `is_wasm_exn(Reason)` ⇒ branch to `L` with **no operands**. Guarded by
  `is_wasm_exn` so a trap / BEAM error is **not** swallowed (spec: `catch_all` catches exceptions, not
  traps).
- **`catch_all_ref L`** — as `catch_all`, operand `[capture_exnref(Reason)]`.
- **No clause matches (incl. no `catch_all`)** — the terminal arm is
  **`reraise(Class, Reason, Stacktrace)`** — faithful propagation to the next outer handler (spec
  §4.4.9). This single arm handles *both* a non-matching wasm exn (re-thrown so an outer `try` can catch
  it) *and* a trap / BEAM error / exit (propagated unchanged — EH never catches a trap).
- **Normal completion** — `of Xs -> Xs` forwards the body's result values as the `TryTable`'s results
  (the `result` types).

**Payload destructuring (cross-unit — P7-06).** `match_tag` returns the payload as a **`List`**; the
branch to `L` wants the tag's operands as **N separate values**. The tag's arity is **static** (from the
`TagDecl` operand signature), so `emit_core` destructures with a fixed-arity let-pattern
(`[V0, V1] = Payload`) before the `Break`. Flagged to P7-06 (§Open questions #4). (This is the mirror of
how `CallImport`'s `fn(List)->List` result list is destructured to a call's result arity — S5.)

### C.3 `ThrowRef(exnref)` → `throw_ref`

```
ThrowRef(exnref)   ⟶   call 'twocore@runtime@rt_exn':'throw_ref'(ExnRef)
```

Bottom. `throw_ref` unboxes a non-null `{ref_exn, Exn}` and re-raises `Exn` identically; a **null**
exnref traps (§G). The legacy proposal's **`rethrow L`** lowers to the *same* `throw_ref` over the
exnref captured at the referenced `catch`/`catch_all` — the neutral IR normalises both surfaces onto one
runtime primitive (§Deviation #1).

### C.4 Constant space + preemption + fuel (J1/J7)

BEAM exception unwinding is **native and constant-space** — a `throw` on a hot loop path does not build
unbounded stack, and the scheduler still preempts at reduction boundaries across the throw/catch (the
same fair-scheduling that makes "JS on the BEAM" viable). **Fuel still bites** (J5): `rt_meter.charge`
raises `error:{wasm_trap, fuel_exhausted}` — a **trap**, so it is **not** caught by a `try_table`
(`is_wasm_exn` is false ⇒ `reraise`), i.e. fuel exhaustion correctly propagates *through* a JS
`try/catch` and is not swallowable. A `throw` itself charges no special fuel — it is an ordinary call
(`Charge` nodes on the surrounding path are unaffected).

---

## D. Per-operation semantics (assert the spec, not the impl)

All references: the WebAssembly **exception-handling proposal**
(<https://github.com/WebAssembly/exception-handling>) and its core-spec integration — the **tag section**
(§5.5, section id **13**), **tag instances / generative identity** (§4.5), the **control-instruction
exec** for `throw`/`try_table`/`throw_ref` (§4.4.9), and **typing** (§3.4). Opcode bytes are cited for
orientation; their authority is P7-03 (decode) — `rt_exn` receives lowered IR and never sees a byte.

### D.1 `throw` (opcode 0x08) — `throw_exn`

`throw x` pops the tag `x`'s operand values and **throws** an exception with tag `x` carrying those
values; it does not return (spec §4.4.9 `throw`). `rt_exn.throw_exn(tag_id, payload)` builds
`{wasm_exn, tag_id, payload}` and `erlang:throw`s it. **Worked:** Porffor's `(tag (param f64 i32))`
thrown with the JS value `Error("neg")` becomes `throw_exn(0, [ErrPtrF64Bits, ObjectTypeTag])` →
`{wasm_exn, 0, [ErrPtrF64Bits, ObjectTypeTag]}`; an enclosing JS `try/catch` (a `catch 0` clause)
matches tag `0`, binds the two operands, and continues.

### D.2 `try_table` (0x1f) / legacy `try` (0x06) + `catch <tag>` — `match_tag` + `Break`

A `try_table` (modern) or `try … catch` (legacy) installs handlers around `body`. A `catch <tag> L`
clause matches a thrown exception **iff its tag is `x`**; on match it **pushes the tag's operand values**
and **branches to `L`** (spec §4.4.9 `try_table` / the legacy `catch`). `rt_exn.match_tag(reason,
tag_id)` returns `Ok(payload)` on match; `emit_core` binds `payload` and `Break`s to `L`. **Worked:**
`match_tag({wasm_exn, 0, [P0, P1]}, 0) = Ok([P0, P1])`; `match_tag({wasm_exn, 1, …}, 0) = Error(Nil)`
(different tag → try the next clause / re-raise); `match_tag({wasm_trap, unreachable}, 0) = Error(Nil)`
(a trap is not a wasm exn → never caught).

### D.3 `catch_ref <tag>` (modern clause kind 0x01) — `match_tag` + `capture_exnref`

As `catch`, but **also pushes an `exnref`** to the caught exception after the operand values (spec:
`catch_ref` binds the exnref). `emit_core` appends `capture_exnref(reason)` to the branch operands.
**Worked:** the branch to `L` carries `[P0, P1, {ref_exn, {wasm_exn, 0, [P0, P1]}}]`.

### D.4 `catch_all` (legacy 0x19 / modern clause kind 0x02) — `is_wasm_exn` + `Break`

Matches **any** exception (any tag), pushing **no** operand values, and branches to `L` (spec:
`catch_all`). **Never catches a trap** — `is_wasm_exn` is the gate. **Worked:**
`is_wasm_exn({wasm_exn, 7, …}) = True` (branch to `L`); `is_wasm_exn({wasm_trap, int_div_by_zero}) =
False` (the `case` `false` arm ⇒ `reraise` — the trap propagates out, uncaught, per spec).

### D.5 `catch_all_ref` (modern clause kind 0x03) — `is_wasm_exn` + `capture_exnref`

As `catch_all`, but the branch operand is `[capture_exnref(reason)]` — an exnref to the caught exception.

### D.6 `throw_ref` (0x0a) / legacy `rethrow` (0x09) — `throw_ref`

`throw_ref` pops an `exnref` and **re-throws** the referenced exception; **if the exnref is null, it
traps** (spec §4.4.9 `throw_ref`). `rt_exn.throw_ref(exnref)` re-raises the captured `{wasm_exn, …}`
identically for a non-null `{ref_exn, _}`, and traps (§G) for the null sentinel. The legacy `rethrow L`
(re-throw the exception caught by the handler at label depth `L`) lowers to the same primitive over the
exnref the neutral IR captured at that handler. **Worked:** `throw_ref({ref_exn, {wasm_exn, 0, [P0,
P1]}})` re-raises `{wasm_exn, 0, [P0, P1]}` — an outer `catch 0` matches it identically;
`throw_ref({ref_null})` → trap.

### D.7 The non-matching re-raise (spec §4.4.9) — `reraise`

When no clause of a `try_table` matches a thrown exception, it **propagates unchanged** to the next
outer handler (spec §4.4.9). `rt_exn.reraise(class, reason, stacktrace)` = `erlang:raise/3` — the BEAM's
native faithful re-raise, preserving **class + reason + stacktrace**, so an outer `try_table` sees the
*identical* exception (same tag, same payload) and a trap that entered the `try` propagates out
byte-for-byte. This is the single most-load-bearing correctness property: **a `try/catch` for tag `A`
must not perturb an exception of tag `B` passing through it.**

---

## E. The `exnref` forge-proof model — reuse `rt_ref` (R1, J2/J5)

An `exnref` is a **reference-layer value** (J2 — a caught-exception handle, opaque like `externref`).
It reuses `rt_ref`'s box discipline (R1) **one tag over**:

| exnref value | Core Erlang term | notes |
|---|---|---|
| a caught exception | `{ref_exn, {wasm_exn, TagId, Payload}}` | the box makes it uncollidable with a raw thrown term, a funcref, an externref, or null |
| null exnref (`(ref null exn)`) | `{ref_null}` | the **shared** `rt_ref` null sentinel — `is_null` is the same test |

**Forge-proof + opaque (J5, H6):**

- **Distinct from every other value.** `{ref_exn, _}` (2-tuple, atom `ref_exn`) collides with none of:
  `{ref_null}` (1-tuple), `{ref_extern, _}` (atom `ref_extern`), a funcref `{FuncType, Closure}` (first
  element a `FuncType` tuple, never the atom `ref_exn`), a raw thrown `{wasm_exn, _, _}` (3-tuple), a
  `v128` (a binary), or a numeric `Int`. So `is_exnref` (and a widened `classify_ref`, §Open questions
  #5) never mis-identifies.
- **Opaque.** `rt_exn` exposes **no unwrap** — Safe code can hold / pass / store / re-throw an exnref
  (via `throw_ref`) but **cannot read** the inner `TagId`/`Payload`. The captured exception's contents
  are invisible to Safe code, exactly as a host term inside `{ref_extern, _}` is (H6).
- **Unforgeable.** Safe WASM code cannot construct `{ref_exn, …}` — the *only* producer is
  `capture_exnref`, reached *only* from a `catch_ref`/`catch_all_ref` clause (or a legacy `rethrow`
  capture). A caught exnref *always* references a real wasm exn (traps are never caught, so a captured
  reason is always `{wasm_exn, …}`), so the box's precondition (`capture_exnref` on a wasm exn) always
  holds.

**Re-throw preserves identity but not the BEAM stacktrace.** `throw_ref` re-raises the captured
`{wasm_exn, …}` via a **fresh `erlang:throw`** (not `raise/3`) — WASM exceptions carry **no observable
stacktrace**, so a fresh throw point is spec-faithful; the tag + payload (the only observable state) are
identical. (Contrast `reraise`, which *does* preserve the stacktrace, because it re-raises a *pass-through*
exception mid-unwind where the BEAM has the triple in hand.)

**Null exnref.** `(ref null exn)` admits null; the null exnref is the shared `{ref_null}` sentinel
(reuse `rt_ref.null_ref`/`rt_ref.is_null`), so a `ref.is_null` over an exnref works with **zero new
machinery**. `throw_ref` on null traps (§G).

---

## F. The uncaught-exception outcome (cross-unit — NOT a trap; run-ABI owns it)

An exception that escapes the **top-level** invoke (no enclosing `try_table` anywhere in the call chain)
is an **uncaught WASM exception**. Per the spec this is **not a trap** — the EH `.wast` corpus asserts it
with a distinct `assert_exception`-style expectation, never `assert_trap`. The run-ABI / harness
(P7-08/P7-09) therefore surfaces it as a **distinct outcome** (e.g. `Uncaught(tag_id, payload)`),
alongside the existing `Trapped(reason)` — the runner's top-level `try` gains one arm:

```erlang
catch throw:{wasm_exn, TagId, Payload} -> <Uncaught(TagId, Payload)>
```

`rt_exn` supports this by making the term shape catchable and classifiable (`is_wasm_exn`/`match_tag`
are reusable by the runner), but **the outcome type is P7-08/P7-09's** (a run-ABI addition), *not* a
`TrapReason`. This keeps the trap taxonomy honest (S8): a WASM exception is **not** a WASM trap, so it
does **not** get a `TrapReason` variant or a `spec_trap_message` entry.

**Why `rt_trap` is (almost) untouched.** The task allows extending `rt_trap` "if an uncaught-exception
trap message is needed." Argued position: it is **not** needed — an uncaught exception is a *separate
outcome*, owned by the run-ABI, not folded into the trap channel. The *only* place `rt_trap` could
legitimately grow is the **`throw_ref`-on-null trap** (§G), which is a genuine spec trap — and even that
is deferred per S8 unless a pinned `.wast` forces it. So this unit's `rt_trap` delta is **at most one
audit arm, likely zero.**

---

## G. `throw_ref`-on-null: a genuine trap (deferred per S8)

`throw_ref` on a **null** exnref **traps** (spec §4.4.9 `throw_ref`: "If `exnref` is `ref.null`, trap").
`rt_exn.throw_ref` guards the null case in Gleam (so it can route to `rt_trap` with a proper reason):

```gleam
pub fn throw_ref(exnref: Dynamic) -> a {
  case rt_ref.is_null(exnref) {
    True -> rt_trap.raise(<reason>)          // spec: throw_ref on null → trap
    False -> ffi_rethrow_exnref(exnref)      // {ref_exn, Exn} → erlang:throw(Exn)
  }
}
```

The `<reason>` is the open question. Per **S8 discipline** (do not pre-add a `TrapReason` speculatively —
add exactly one *consciously* only if a pinned `.wast` empirically needs a message the existing set
cannot produce): the recommendation is to **defer** — measure the pinned `throw_ref.wast` at the SHA
(P7-09/P7-10) and, *only if* it asserts a message no existing reason yields, add **one** keystone
`TrapReason` variant (e.g. `NullExnRef`) whose `spec_trap_message` arm (the single `rt_trap` extension
this unit would then carry) returns the asserted substring. Until measured, `throw_ref`-on-null is a
**categorized proof** (Porffor never emits `throw_ref`/`rethrow` — §Deviation #1 — so it is
engine-completeness, not corpus-blocking). Flagged (Open questions #2). `rt_exn`'s body is written so the
guard is present and total *now*; only the `<reason>` literal is pending the keystone's call.

---

## Effect / soundness / security note

- **A thrown value is a term, never authority (D3a/J5).** `throw_exn` builds a fixed-shape
  `{wasm_exn, TagId, Payload}` and hands `Payload` as **data**; nowhere on the throw/catch/rethrow path
  does `rt_exn` construct a module/function atom from `TagId`/`Payload` or call `apply/3` — it
  `erlang:throw`s a fixed tuple, `erlang:raise/3`s a *captured* triple, and pattern-matches a term.
  Grep-asserted (Verification #9): `rt_exn.gleam` + the FFI shim contain **no** `apply`, no
  `binary_to_atom`, no module-name construction. The keystone's D3a `emit_core` test is extended to the
  EH seam (no ambient authority in the emitted `try`).
- **Fail-closed by construction.** `match_tag`/`is_wasm_exn` match the **exact** term shape; anything
  that is not a `{wasm_exn, …}` (a trap, a BEAM error, an exit) is **re-raised**, never swallowed — the
  worst case of a bug is a *wrongly-propagated* or *wrongly-caught wasm exn*, never a **swallowed trap**
  (which would be a sandbox hole: a fuel-exhaustion or OOB trap must always bite). `catch_all` is gated
  on `is_wasm_exn` for exactly this reason.
- **Forge-proof, opaque exnref (H6/J5).** Safe code cannot forge `{wasm_exn, …}` or `{ref_exn, …}` (no
  WASM op constructs them) and cannot read a caught exnref's contents (no unwrap exposed). It may
  re-throw an exnref (`throw_ref`) but cannot inspect or fabricate one.
- **Traps are orthogonal to EH (spec).** A `{wasm_trap, Kind}` inside a `try_table` body is **never**
  caught (`is_wasm_exn` false ⇒ `reraise`) — so `MemoryOutOfBounds`, `IntDivByZero`, `Unreachable`, and
  `FuelExhausted` all propagate *through* a JS `try/catch` exactly as the spec requires. EH does not
  weaken the sandbox: an uncaught WASM exception is a BEAM exception the instance boundary contains
  (one-instance-one-process), unable to escape to other instances or the node.
- **Preemption + constant space survive (J1/J7).** Native BEAM unwinding is constant-stack and
  preemptible; a throw on the hot path is a well-behaved BEAM citizen. Metering is unaffected (a throw is
  an ordinary call; fuel charges continue; fuel exhaustion is an un-catchable trap).
- **Tier-P, runs anywhere.** `rt_exn` is pure term construction/matching + native `throw`/`raise` — no
  OTP state, no NIF; it cannot crash the node and runs on every BEAM. (One **cross-unit soundness seam**
  it does *not* own but must flag: EH interacts with the **Threaded** state strategy — see the
  cross-unit flags. `rt_exn` itself is state-agnostic.)
- **Conformance-neutral by default (J6).** A module with **no tags** links **no** `rt_exn` — so it
  decodes/validates/lowers/emits **byte-identically** to Phase-6 under both modes and every tier. This is
  automatic (there is no Phase-6 `rt_exn` to differ from); the unit only avoids perturbing `rt_ref`/
  `rt_trap` (which it never edits — D1).

---

## Verification — Definition of Done (D8: assert the spec, not the impl)

Write the spec-cited suite (cite the exception-handling proposal exec §4.4.9, the tag section §5.5, tag
identity §4.5, and — for the JS surface — Porffor's measured `(tag (param f64 i32))` + `throw`/`try`/
`catch`). Assert the **spec-defined behaviour**, not whatever the code emits (no change-detector tests).
The plan:

1. **Throw/catch round-trip (D.1/D.2).** `throw_exn(0, [P0, P1])` caught by a `match_tag(_, 0)` yields
   `Ok([P0, P1])` — the payload survives intact (bit-exact for numeric operands, D5). Drive it both as a
   direct `rt_exn` call *and* through an emitted `try` (a small hand-authored IR `TryTable` over a
   `Throw`) so the composition (§C.2) is exercised end-to-end.
2. **Non-matching tag → re-raise (D.7).** A `try` for tag `0` around a `throw_exn(1, P)` **does not
   catch** — the exception propagates out and an *outer* `try` for tag `1` catches it with the **identical
   payload** (`match_tag` `Error` on the inner, `Ok` on the outer). This is the property that makes
   nested handlers correct.
3. **Faithful re-raise preserves the exception (D.7).** `reraise(Class, Reason, Stacktrace)` re-raises the
   *same* term (assert the caught reason `=:=` the original) with the *same* class; a wasm exn re-raised
   is re-catchable by tag, a trap re-raised is still a trap.
4. **`catch_all` catches any exn but NOT a trap (D.4).** `is_wasm_exn({wasm_exn, k, _}) = True` for
   several `k`; `is_wasm_exn({wasm_trap, Kind}) = False` for every `Kind` (incl. `fuel_exhausted`,
   `memory_out_of_bounds`, `unreachable`) — so a `catch_all` around a trapping body **re-raises the
   trap** (assert the trap escapes the `try`, not swallowed). This is a *security* assertion (S8: a trap
   must always bite).
5. **Nested try/catch unwinding.** An inner `try` (tag `A`) inside an outer `try` (tag `B`), body throws
   `B`: the inner does **not** catch (re-raise), the outer **does** — assert the control lands in the
   outer handler with `B`'s payload. Then the mirror (throw `A`): inner catches, outer untouched. Then a
   trap in the inner body: **neither** catches; it escapes both.
6. **`catch_all` + inner `catch <tag>` ordering.** Clauses tried in order: a `try` with
   `[catch A → L1, catch_all → L2]` routes an `A` to `L1` and a `B` to `L2` (assert the *first* matching
   clause wins, spec).
7. **exnref capture + `throw_ref` re-throw (D.3/D.6/§E).** `capture_exnref({wasm_exn, 0, P})` =
   `{ref_exn, {wasm_exn, 0, P}}`; `throw_ref` of it re-raises `{wasm_exn, 0, P}`, re-caught by an outer
   `match_tag(_, 0) = Ok(P)` — a full capture → re-throw → re-catch round-trip. Assert `is_exnref` is
   `True` on the box and `False` on a funcref/externref/null/raw-exn/`v128`/Int (no collision, §E).
8. **Null `throw_ref` traps (D.6/§G).** `throw_ref(rt_ref.null_ref())` raises a **trap** (an
   error-class `{wasm_trap, _}`), *not* a wasm exn — assert it is caught by a trap handler and **not** by
   a `match_tag`/`is_wasm_exn` (it is not a wasm exn). (If the keystone has not yet fixed the reason,
   assert the class/outer-tag is a trap and pin the exact `Kind` once §G resolves.)
9. **D3a (grep-backed).** `rt_exn.gleam` + `twocore_rt_exn_ffi.erl` contain **no** `apply`, no
   `erlang:binary_to_atom`, no module-name construction — only fixed-tuple construction/matching and
   `erlang:throw`/`raise/3` (grep-asserted in the test module, mirroring the P5/P6 backend D3a checks).
10. **Opacity / forge-proofness (§E/H6).** There is **no** public `rt_exn` function that returns an
    exnref's inner `TagId`/`Payload` (assert by API inspection — the module exports no unwrap). A crafted
    `{ref_extern, {wasm_exn, 0, P}}` (a host term that *looks* like a captured exn) is **not** an exnref
    (`is_exnref = False`) and **not** throwable via `throw_ref` (it is not `{ref_exn, _}`) — the box, not
    the contents, is the identity (the same argument as `rt_ref`'s `{ref_extern, {ref_null}}` ≠ null).
11. **Payload heterogeneity (D5).** A payload mixing an `Int` (numeric raw bits), a 16-byte `BitArray`
    (`v128`), and a reference `Dynamic` round-trips through `throw_exn`/`match_tag` **bit-identically**
    (the list carries them opaquely; no coercion).
12. **Porffor-shaped case.** A two-element `(f64, i32)` payload (the measured Porffor tag) throws and
    catches with both operands intact — the concrete shape the JS harness (P7-09) depends on.
13. **Property tests (spec laws, `gleeunit`-randomised).** For random `tag_id`/payload: `match_tag(throw
    term of tag t, t) = Ok(payload)` and `match_tag(…, t') = Error` for `t' ≠ t`; `is_wasm_exn(any thrown
    wasm exn) = True`; `is_wasm_exn(any {wasm_trap, k}) = False`; `capture_exnref` then `throw_ref` then
    catch = the original payload (round-trip identity); `is_exnref(capture_exnref(x)) = True`. Properties
    assert **spec identities**, never impl internals.
14. **Conformance readiness (wired by P7-09/P7-10, proven here).** `rt_exn` is the engine under the EH
    `.wast` corpus — `throw.wast`, `try_catch.wast` (or `try_table.wast` at the pin), `tag.wast`,
    `throw_ref.wast` where `wast2json`-able (else an authored in-scope proof, R16 discipline) — **fail=0**,
    with the uncaught-exception outcome (§F) judged against the spec's `assert_exception` expectation.

**Gate:** `gleam format --check src test` clean; `gleam build` **zero warnings** (no lingering `todo` in
`rt_exn.gleam`); `gleam test` stays green (the existing 1491 + your new suite); every new public
function/type carries a `///` contract doc (D8). **Done = the spec-cited suite + the property suite + the
cited EH `.wast` files (or authored proofs) pass**, never "it compiles."

---

## What this unit leaves

- **P7-06 (emit_core):** lowers `Throw`/`ThrowRef` to `throw_exn`/`throw_ref` calls and `TryTable` to the
  Core Erlang `try … catch` composition (§C) — the per-clause `match_tag`/`is_wasm_exn`/`capture_exnref`
  chain terminating in `reraise`, the **payload list → tag-arity destructuring** (§C.2), and the
  `Break(label, operands)` to the enclosing block; extends the D3a security test to the EH seam.
- **P7-01 (keystone):** freezes §B (`«RT-EXN-SIG»`, `todo` bodies) so 06 emits immediately; freezes
  `Module.tags`/`TagDecl` + `Throw`/`TryTable`/`ThrowRef` + the `exnref`/`TExnRef` value; classifies the
  EH nodes as **effectful barriers** in `ir/effect.gleam`; decides the `throw_ref`-on-null `TrapReason`
  (§G — default: none, S8); assigns `TagId` (§A.3).
- **P7-03/04/05 (decode/validate/lower):** map **both** the modern (`try_table`/`throw`/`throw_ref`) and
  the **legacy** (`try`/`catch`/`catch_all`/`delegate`/`rethrow` — what real Porffor emits, Deviation #1)
  WASM EH surfaces onto the one neutral IR (`Throw`/`TryTable`/`ThrowRef`), so `rt_exn`'s seven primitives
  serve every surface; validate types the tag operands / catch labels / `exnref` fail-closed.
- **P7-08 (Porffor shim / run-ABI):** owns the **uncaught-exception outcome** (§F — not a `TrapReason`),
  the `(f64, i32)` value-ABI decode of a returned/thrown JS value, and the **cross-module tag identity**
  assignment (§A.3) if the corpus reaches imported/exported tags.
- **P7-09/10 (JS + conformance):** drive the EH `.wast` corpus + the Porffor JS corpus (whose `try/catch`
  → the legacy `try`/`catch` `rt_exn` runs), judge the uncaught-exception outcome against
  `assert_exception`, and report measured greenness (R16).

---

## Deviations from the overview / ABI findings (ARGUED)

1. **MEASURED: Porffor 0.61.13 emits the LEGACY EH proposal (`try`=0x06 / `catch`=0x07), NOT modern
   `try_table` (0x1f).** Re-probing the installed compiler (`npx porffor wasm foo.js` +
   `wasm-tools print --print-offsets` + a raw-byte dump) shows the actual EH surface is the **legacy
   try/catch** proposal: the byte at the handler is `0x06` (`try` + empty blocktype `0x40`), the handler
   clause is `0x07 0x00` (`catch` tag `0`), `throw` is `0x08 0x00`, and even a nested `try/finally`
   stays `try`/`catch`. It emits **exactly one** `(tag (param f64 i32))` (section id **13**, id shared by
   both proposals), `throw <tag>`, and `try … catch <tag> … end` — **no** `try_table` (0x1f), **no**
   `throw_ref` (0x0a), **no** `exnref`, and (in these probes) **no** `catch_all`/`delegate`/`rethrow`.
   This **contradicts** both [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md) ("try/catch JS →
   try_table/catch") and the task framing ("the MODERN one Porffor emits … NOT the legacy
   try/catch/delegate/rethrow"). **Impact on this unit: none** — `rt_exn`'s seven primitives are the
   *neutral* runtime target, and legacy `try`/`catch`/`catch_all`/`rethrow` and modern
   `try_table`/`catch*`/`throw_ref` **both** lower to the same `Throw`/`TryTable`/`ThrowRef` IR → the
   same `throw_exn`/`match_tag`/`is_wasm_exn`/`capture_exnref`/`throw_ref`/`reraise` calls (legacy
   `rethrow L` ≡ modern `throw_ref` over the captured exnref; legacy `catch_all` ≡ modern
   `catch_all`/`_ref`). **Impact downstream: real** — **P7-03 (decode) MUST handle the legacy surface**
   (opcodes 0x06 `try` / 0x07 `catch` / 0x19 `catch_all` / 0x18 `delegate` / 0x09 `rethrow` / 0x0b `end`)
   to run real Porffor output; the modern `try_table`/`throw_ref` (0x1f/0x0a) is **engine-completeness**
   for the EH `.wast` corpus, not Porffor-required. This is the load-bearing cross-unit flag; the
   reconciliation must fold it into 00-overview / PORFFOR-ABI-FINDINGS and P7-03's scope. (This unit is
   written surface-agnostic precisely so the deviation costs it nothing.)
2. **`rt_exn` is doc-frozen at 7 heads, not "throw + a match helper".** The overview J1/J2 sketch is
   "`throw` → raise; `try_table` → a Core Erlang try that matches the tag … re-raises non-matching;
   `throw_ref` → re-raise". Made concrete, that is **seven** primitives (§B): `throw_exn`, `match_tag`
   (per-clause), `is_wasm_exn` (the `catch_all` gate — *distinct* from `match_tag` because `catch_all`
   must catch any exn but no trap), `reraise` (the faithful `raise/3` fall-through), `capture_exnref` +
   `throw_ref` (the exnref pair), and `is_exnref` (the classifier). The split of `catch` vs `catch_all`
   into `match_tag` vs `is_wasm_exn` is the argued refinement — it is what lets `catch_all` be spec-exact
   (catch exceptions, never traps). Flagged for the keystone to freeze this exact set.
3. **The exnref reuses `rt_ref`'s box `{ref_exn, _}` — a new reserved atom, not a new module.** J2 says
   "`exnref` is a new reference-layer value (opaque like `externref`)" and the task says "reuse rt_ref's
   model." Made concrete: `rt_exn` owns a **new** box tag `{ref_exn, {wasm_exn, …}}` (D1 — `rt_exn`'s
   own FFI, not an edit to `rt_ref`), sharing `rt_ref`'s **null sentinel** and **box discipline**. The
   only `rt_ref` seam is the *optional* `classify_ref` widening (§Open questions #5) — needed **only** if
   the corpus returns an exnref across the invoke ABI (Porffor never does). Flagged so ownership is clean.
4. **`rt_trap` is (at most) minimally touched — an uncaught exception is NOT a trap.** The file-ownership
   map lists "`rt_trap.gleam` extend". Argued down to **conditional/zero** (§F/§G): an *uncaught*
   exception is a **run-ABI outcome** (P7-08), not a `TrapReason`; the *only* legitimate `rt_trap` growth
   is one `spec_trap_message` arm for the `throw_ref`-on-null **trap**, itself **deferred per S8** until a
   pinned `.wast` needs it. So this unit's `rt_trap` delta is **at most one audit arm, likely zero** —
   the trap taxonomy stays honest.

---

## Open questions (for the planner / cross-unit sync)

1. **Payload list → tag-arity destructuring at the catch (P7-06).** `match_tag` returns the payload as a
   `List`; the branch to the catch label wants the tag's operands as N separate values. Confirm
   `emit_core` destructures with a fixed-arity let-pattern from the static `TagDecl` arity (§C.2) — the
   mirror of the S5 `CallImport` result-list destructuring. (Recommended; `rt_exn` returns the list
   unchanged.)
2. **The `throw_ref`-on-null `TrapReason` (§G / keystone P7-01).** Spec: `throw_ref` on null traps. No
   existing `TrapReason` names it. Recommend **deferring** (S8) — measure `throw_ref.wast` at the pin;
   add **one** variant (`NullExnRef` + its `spec_trap_message` substring) *consciously* only if the file
   asserts a message the existing set cannot produce. Until then, `rt_exn.throw_ref`'s null guard routes
   to a placeholder reason the keystone fixes. (Porffor never emits `throw_ref`, so this is
   engine-completeness, not corpus-blocking.)
3. **Cross-module tag identity (§A.3 / P7-05 lower + P7-08 link).** `TagId` is a module-local `Int` index
   (correct + sufficient for the single-module Porffor + most EH `.wast`). For imported/exported tags
   (`tag.wast`), the linker must assign **distinct** `TagId`s to distinct definitions and the **same**
   `TagId` to an imported tag + its export (generative identity, spec §4.5). Confirm the linker owns this;
   `rt_exn` only needs *equal `TagId` ⟺ same tag*. If an opaque token is preferred over an `Int`, the
   interface widens with **no** body change (equality is `=:=` either way) — flag before freeze.
4. **The exception CLASS choice (throw) — confirm with the run-ABI (P7-08).** `throw_exn` uses **throw**
   class (JS `throw` → BEAM `throw`; distinct from the error-class trap channel). The correctness of
   catch/re-raise does **not** depend on this (the match is on the term shape). Confirm the run-ABI's
   top-level `try` catches `throw:{wasm_exn, …}` for the uncaught-exception outcome (§F).
5. **`classify_ref` widening for `exnref` (rt_ref owner).** If the EH `.wast`/JS corpus **returns** an
   exnref across the invoke/result ABI (Porffor does not), the harness's reference classifier needs an
   `ExnRef` arm. `rt_exn` provides `is_exnref`; whether `rt_ref.classify_ref` grows an arm (a `rt_ref`
   edit, its owner's call) or the harness composes `rt_exn.is_exnref` is a cross-unit decision. Recommend
   the harness composes `is_exnref` (keeps `rt_ref` untouched, D1) unless a corpus case forces the
   `RefKind` extension.
6. **EH × the Threaded state strategy (P7-06 + the state owner) — a soundness seam `rt_exn` does not own
   but must flag.** Under **Cell** (tier-O, the Safe default, pdict) a throw/catch preserves WASM state
   natively: memory/global mutations before the throw live in the process dictionary, which **survives**
   the BEAM unwind, so the catch handler sees post-mutation state (spec-correct — a throw does not roll
   back memory). Under **Threaded** (tier-P, state threaded as an `InstanceState` record through returns)
   a BEAM exception unwinds **past** the functionally-threaded `cur`, so mutations made in the `try` body
   would be **lost** at the catch — spec-incorrect. Resolution options for P7-06 / the state owner:
   (a) EH is spec-correct under **Cell** and used there by default (Porffor runs Cell); (b) under
   **Threaded**, `emit_core` must recover the body's `cur` across the catch (thread it out-of-band), or
   Threaded+EH is **categorized honestly** as unsupported (the P5/S5 precedent for an invasive
   cross-tier case). `rt_exn` is **state-agnostic** (it operates only on the exception term), so it does
   not constrain the choice — but the reconciliation must pin it, because "JS on the BEAM" defaults to
   Cell and the claim must be honest about Threaded.
