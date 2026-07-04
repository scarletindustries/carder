# Phase 8 · Unit 05 — The `rt_js` runtime boundary (capability chokepoint)

> Read [`00-overview.md`](00-overview.md) (K6) + the **Phase-7 `rt_host` Porffor shim** (`specs/phase-7/
> 08-porffor-shim.md`, `src/twocore/runtime/rt_host.gleam`) — this unit is the exact same pattern for a
> new runtime. Files: the host binding + `emit_call_host` path (`emit_core.gleam` `resolve_stdlib` /
> the binding chokepoint), `middle/ir_lower.gleam` (capability gating), a new `src/twocore/runtime/
> rt_js.gleam` **stub**, tests.

## Design (K6, D3a)

JS-semantic operations — property get with prototypes, `ToPrimitive`/`ToNumber` coercion, `+`, `typeof`,
builtins, mutable **cells** (unit 02), the `undefined` sentinel — are **not** IR nodes. The frontend
emits `CallHost("js", op, args)` and the **binding chokepoint** routes it to a **build-fixed** function
in a designated JS-runtime module (`rt_js`) via a **literal `case`** — **never `apply(Mod,Fn,Args)` from
data** (D3a). Unknown `op` ⇒ typed failure, **fail-closed**. This is byte-for-byte the discipline of the
Phase-7 Porffor shim; **mirror it, do not invent a new mechanism.**

The `rt_js` **module itself is the frontend team's deliverable** (all JS semantics live there). Phase 8
ships only (a) the *boundary* — the fixed dispatch that recognises the `"js"` capability and routes to
`rt_js`, fail-closed; (b) the `ir_lower` gating that admits `"js"` alongside `"std"`/declared imports;
(c) a **minimal `rt_js` stub** with a couple of ops so the boundary is testable now.

## What to ship

1. **Capability gating** (`ir_lower`): `CallHost("js", …)` is admitted (not `ForbiddenHost`), exactly
   as `"std"` is. Everything still fails closed by default.
2. **The fixed dispatch** (`emit_call_host` / `resolve_stdlib` or the sibling that Phase-7 added for
   `rt_host`): a literal `case op of "type_of" -> rt_js:type_of/1; "add" -> rt_js:add/2; … ; _ ->
   <typed error> end` bound at build time to the `rt_js` module atom (via the binding record, like
   `stdlib_module`/the porffor shim module). Add a `js_runtime_module` binding field mirroring
   `stdlib_module`. **No dynamic apply.**
3. **`rt_js` stub** (`src/twocore/runtime/rt_js.gleam`): a handful of real ops so tests pass and the
   ABI is demonstrated — e.g. `pub fn add(a, b)` (numeric add on boxed terms), `pub fn type_of(x) ->
   binary` (a `typeof`-style classifier), `pub fn undefined_sentinel()`. Keep it tiny and clearly
   marked "STUB — the real rt_js is the frontend's" (`HANDOFF-arc-frontend.md` lists the ABI the
   frontend must ultimately provide). `CallHost` returns exactly **one** value (Phase-1 rule) — ops
   that need multiple results return a tuple.

## Effect

`CallHost("js", …)` is already an `Effectful` **barrier** (unchanged) — good; JS runtime calls may do
anything.

## Tests (spec-first)

- `CallHost("js", "add", [box 2, box 3])` → the boxed `5` (through the stub); `CallHost("js",
  "type_of", [box 1.0])` → the `typeof` binary the stub returns; `CallHost("js",
  "undefined_sentinel", [])` → the sentinel.
- **Fail-closed:** `CallHost("js", "nonexistent", […])` produces the **typed error** (`ir_lower`/emit
  path), never a panic, never `apply`. Assert the error, and that no code path can reach an arbitrary
  MFA from `op` data (D3a — the security test style of `emit_core_security_test.gleam`).
- Conformance-neutral: WASM byte-identical; the `"js"` capability is inert for any module that never
  uses it.

## Definition of Done

Suite green (≥1694, 0 failures), format/build clean, WASM byte-identical, D3a security test green.
Commit `phase-8/05: rt_js runtime boundary (fixed, fail-closed)` and push.
