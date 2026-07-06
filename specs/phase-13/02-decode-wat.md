# Q13-02 — Ingest: decode `0x12`/`0x13` + WAT `return_call` / `return_call_indirect`

> **Status:** scoped, awaiting build. **Owner:** Q13-02 (Wave A, parallel behind `«TC-FROZEN»`).
> **Depends on:** `«TC-FROZEN»` (Q13-01) — the two AST constructors must already exist. **Produces:** no
> new frozen signature; it makes the two tail-call opcodes/mnemonics *reachable* from real inputs.
> **Read order:** [`00-overview.md`](00-overview.md) → the distilled codebase map → this doc.
> All prior-phase decisions and the permanent invariants
> ([`../03-phase-workflow.md`](../03-phase-workflow.md) §8) still hold.
> This unit is **purely additive**: both target dispatchers already have a fall-through arm
> (`decode` → `Error(ast.UnknownOpcode)`; `wat` → `unsupported_or_unknown`), so a module that uses
> **neither** instruction decodes/parses **byte-identically** to Phase 12 (Q6).

---

## §1. Goal

Wire the front door. After the keystone added `ast.ReturnCall` / `ast.ReturnCallIndirect` to the AST,
this unit teaches the **two ingest paths** to *produce* those nodes:

- **Binary decode** — opcode `0x12` (`return_call`) and `0x13` (`return_call_indirect`), reading
  **immediates byte-identical to `0x10` / `0x11`** (Q2). A funcidx `u32` for `0x12`; a typeidx `u32`
  **then** a tableidx `u32` for `0x13` (anti-swap field order preserved).
- **WAT text parse** — mnemonics `"return_call"` and `"return_call_indirect"`, sharing the exact index /
  typeuse resolution machinery `"call"` / `"call_indirect"` already use.

Both are syntactic-only: this unit produces AST nodes and asserts they round-trip. **No validation, no
lowering, no emission** — those are Q13-03/04/05. The keystone's conservative-sound `lower`/`validate`/
`emit` placeholder arms already keep the *whole* pipeline compiling, so the modules this unit newly
ingests do not break `gleam build`; but this unit's own tests stop at the AST (`decode.decode` /
`wat.parse_module`), which do not lower.

Implements **Q2** (the two opcodes / two AST constructors → ingest) and preserves **Q6** (byte-identical
default) and **Q8** (only the two instructions; `return_call_ref` and every typed-ref/GC neighbour stay
out of scope and must still be rejected as unknown/unsupported).

---

## §2. Depends on / Produces

**Depends on (read-only, frozen upstream — do NOT edit these):**

- `src/twocore/frontend/wasm/ast.gleam` (owned by Q13-01, `ast.gleam:585-589` neighbourhood). The two
  constructors this unit *consumes*, exactly (Q2, anti-swap field names mirroring `Call` / `CallIndirect`):

  ```gleam
  ReturnCall(func: Int)                       // 0x12  — sibling of Call(func: Int)
  ReturnCallIndirect(type_idx: Int, table: Int)  // 0x13 — sibling of CallIndirect(type_idx, table)
  ```

  If these are not present under `«TC-FROZEN»`, **stop and raise with the planner** — do not add them here
  (that would break D1: `ast.gleam` is single-owned by the keystone).

**Produces:** no new public signature and no freeze token. It flips two opcodes from
`Error(UnknownOpcode)` → `Ok(node)` and two mnemonics from `UnknownMnemonic` → `Ok(node)`. Unblocks the
capstone's end-to-end drive (Q13-06) once Q13-03/04/05 also land; **not** on the critical path of any
sibling Wave-A unit (validate/lower/emit build against the frozen AST + IR, not against decode/wat).

---

## §3. What it owns + design

**Owned files (D1 — one substantive owner each):**

- `src/twocore/frontend/wasm/decode.gleam` — add the `0x12` / `0x13` arms.
- `src/twocore/frontend/wasm/wat.gleam` — add the two mnemonics (+ a small, in-file refactor of
  `call_indirect_instr`).
- **new** `test/twocore/frontend/wasm/tail_call_ingest_test.gleam` — this unit's focused round-trip suite
  (a dedicated module, so it touches no shared test file and cannot collide with a sibling unit).

No cross-file reaches. No edit to `ast.gleam`, `lower.gleam`, `validate.gleam`, `emit_core.gleam`,
`ir.gleam`, or any conformance wiring.

### 3.1 `decode.gleam` — the two arms (anchors: `decode.gleam:1215-1223`, helper `:1268`/`:1393`)

`decode_instr` (`decode.gleam:1176`) is a flat `case op { … }`. The control block already handles
`0x0F Return` (`:1214`), `0x10 Call` (`:1215-1218`) and `0x11 CallIndirect` (`:1219-1223`). Insert the two
new arms **immediately after the `0x11` arm** (they are control instructions; keep them grouped with the
`0x10`/`0x11` siblings):

```gleam
// tail-call proposal (Q13): immediates identical to 0x10 / 0x11.
0x12 -> idx_instr(rest, ast.ReturnCall)          // one u32 funcidx
0x13 -> {
  use #(ty, r1) <- result.try(decode_u_n(rest, 32))
  use #(table, r2) <- result.try(decode_u_n(r1, 32))
  Ok(#(ast.ReturnCallIndirect(type_idx: ty, table: table), r2))
}
```

- `0x12` reuses the existing `idx_instr` helper (`decode.gleam:1393`, `use #(i,r) <- decode_u_n(bytes,32)`)
  — the same helper `0x20`..`0x24` use (`:1268`). One `u32` funcidx, fail-closed `Truncated` on shortfall.
- `0x13` **copies the `0x11` body verbatim** (`:1219-1223`) with only the constructor changed — typeidx
  `u32` first, tableidx `u32` second, `type_idx:` / `table:` labelled to lock the anti-swap order. Do
  **not** collapse the two reads into `idx_instr`; the two-immediate shape must match `CallIndirect`
  exactly so a future field reorder can't silently pass.

**Do NOT touch** `decode_expr` (`:1168`) — `return_call` / `return_call_indirect` are ordinary stream
instructions, **not** block openers/closers; they carry no nesting-depth bookkeeping and reach the
existing `_ -> decode_expr(rest, depth, …)` accumulator arm unchanged. **Do NOT touch** `leaf_instr`
(`:1331`) or the `0xFC`/`0xFD` prefix dispatch — `0x12`/`0x13` are primary-`case op` opcodes handled
before those tiers are reached.

The pre-existing fall-through `_ -> Error(ast.UnknownOpcode(op))` (`decode.gleam:1350`) is what these two
arms *supersede* for these bytes; every other unknown byte still lands there (Q6/Q8).

### 3.2 `wat.gleam` — the two mnemonics (anchors: `wat.gleam:3175`, `:3331`)

The mnemonic dispatch is the `case kw { … }` at `wat.gleam:3165`. `"call"` is `one_idx(…, ast.Call, …)`
(`:3175`) and `"call_indirect"` is `call_indirect_instr(toks, env, types, pos)` (`:3180`, body
`:3331-3351`). Two edits:

**(a) `return_call`** — one funcidx, exactly like `"call"`. Add next to the `"call"` arm (`:3175`):

```gleam
"return_call" -> one_idx(toks, env.funcs, "func", ast.ReturnCall, types)
```

`one_idx` (`wat.gleam:3267`) resolves a single index token against the func name-map and fails
`UnexpectedEof("func index")` if the operand is missing — identical ergonomics to `"call"`.

**(b) `return_call_indirect`** — same optional-table + typeuse grammar as `"call_indirect"`. Parametrize
the existing `call_indirect_instr` with the AST constructor (this is an **in-file** refactor of a file
this unit owns — no D1 issue):

```gleam
// dispatch arms:
"call_indirect"        -> call_indirect_instr(toks, env, types, pos, ast.CallIndirect)
"return_call_indirect" -> call_indirect_instr(toks, env, types, pos, ast.ReturnCallIndirect)

// call_indirect_instr (wat.gleam:3331) gains a trailing param and threads it to the tail:
fn call_indirect_instr(
  toks: List(Token),
  env: Env,
  types: List(ast.FuncType),
  pos: Pos,
  ctor: fn(Int, Int) -> ast.Instr,
) -> Result(#(List(ast.Instr), List(Token), List(ast.FuncType)), WatError) {
  // … unchanged table + typeuse parsing …
  Ok(one(ctor(type_idx, table), r2, types1))   // was: ast.CallIndirect(type_idx, table)
}
```

This keeps **one** implementation of the optional-`tableidx?` + `(type $ft)` typeuse path shared by both
mnemonics (guarantees the tail form can never diverge from the plain form). The alternative — a `_twin`
that duplicates the body — is acceptable only if the refactor proves awkward; prefer the parametrized
form. Update the `call_indirect_instr` doc comment to note it now backs both `call_indirect` and
`return_call_indirect`.

The pre-existing fall-through `_ -> … unsupported_or_unknown(kw, pos)` (`wat.gleam:3207-3214`, helper
`:3558`) is untouched: `return_call_ref` and every SIMD/GC mnemonic still route to
`Unsupported`/`UnknownMnemonic` (Q8 — proven by an adversarial test, §5).

---

## §4. The work (ordered, buildable)

1. Confirm `«TC-FROZEN»` in `state.md` and that `ast.ReturnCall` / `ast.ReturnCallIndirect` exist with the
   §2 signatures. (If absent → raise, don't add.)
2. `decode.gleam`: add the `0x12` / `0x13` arms after `:1223` (§3.1). Add a `//` comment citing the
   tail-call proposal + the immediate identity with `0x10`/`0x11`.
3. `wat.gleam`: add the `"return_call"` arm (§3.2a) and the `"return_call_indirect"` arm; refactor
   `call_indirect_instr` to take the `ctor` param and route both mnemonics through it (§3.2b). Refresh its
   doc comment.
4. `gleam format` → `gleam build` (**zero warnings**).
5. Write `test/twocore/frontend/wasm/tail_call_ingest_test.gleam` (§5). `gleam test -- twocore/frontend/wasm/tail_call_ingest_test`
   green; then the full `gleam test` green (byte-identical default — the decode/wat regression suites,
   including `wat_test`'s `diff` differential corpus, must be unchanged).
6. Update `state.md`: Q13-02 complete, no new frozen signature, no cross-file reach.

---

## §5. Tests (`tail_call_ingest_test.gleam`) — spec-cited + adversarial

Tests assert the **WebAssembly tail-call proposal binary/text grammar**, not emitted text — objective,
not change-detector. The proposal fixes: `return_call $f` takes one funcidx immediate identical to `call`;
`return_call_indirect $t (type $ft)` takes a typeidx-then-tableidx pair identical to `call_indirect`. This
unit proves **syntax only**; the typing rule (result-type equality) is Q13-03's `assert_invalid` surface
and is **explicitly out of scope here** (§7).

Fixture provenance: prefer embedding a small `.wasm` byte-array constant with the assembling WAT quoted in
a `//` comment for provenance (the established `fib_wasm` / `mv_wasm` pattern in `decode_test.gleam`).
Produce it once via `wat2wasm --enable-tail-call`; if that build lacks the flag, hand-author the module and
document the byte layout in the comment. The *load-bearing* bytes are the code-section opcodes
(`0x12`, `0x13`); `decode.decode` returning `Ok` is itself the proof the section framing is well-formed.

**Binary decode round-trip (`0x12` → `ast.ReturnCall`):**
1. A module whose function body contains `return_call $f` decodes to `Ok`, and the target `func.body`
   equals the expected instruction list with `ast.ReturnCall(<funcidx>)` in place — proving the node is
   produced with the correct funcidx.
2. **UnknownOpcode no longer fires:** decoding the same module returns `Ok(_)` (not
   `Error(ast.UnknownOpcode(0x12))`). Assert on `Ok` specifically so a regression that drops the arm
   fails loudly. (Optionally assert the negative directly: the pre-Q13 behaviour would have been
   `Error(UnknownOpcode(0x12))`.)

**Binary decode round-trip (`0x13` → `ast.ReturnCallIndirect`):**
3. A module with a table + one `type` and a body containing `return_call_indirect (type $ft)` decodes to
   `Ok` and yields `ast.ReturnCallIndirect(type_idx: <t>, table: <tbl>)`. **Anti-swap assertion:** with a
   fixture whose typeidx ≠ tableidx (e.g. type index 1, table 0), assert `type_idx == 1 && table == 0` —
   locks the immediate order against a field swap.

**WAT parse round-trip:**
4. `wat.parse_module("(module (func $a) (func (return_call $a)))")` → `Ok`, and the second func's body
   contains `ast.ReturnCall(0)` (symbolic `$a` resolves to funcidx 0).
5. `wat.parse_module` of a module with `(table 1 funcref)`, an `(elem …)`, a `(type $ft (func …))`, and a
   body `(return_call_indirect (type $ft))` → `Ok`, body contains
   `ast.ReturnCallIndirect(type_idx: <resolved>, table: 0)`. Cover the **explicit-table** form
   (`return_call_indirect $tbl (type $ft)`) too, asserting the table index is the resolved `$tbl` — proves
   the optional-tableidx path is shared with `call_indirect`.

**WAT ↔ binary equivalence (where feasible):**
6. A `diff_tail(text)` helper local to this test module: assemble `text` with
   `wat2wasm … --enable-tail-call`, then assert `decode.decode(bytes) == wat.parse_module(text)`
   (structural AST equality — the same contract as `wat_test.gleam`'s `diff`, `:69-94`). **Skip-if-absent
   AND skip-if-unsupported:** return `Nil` (pass) when `wat2wasm` is not found *or* when the assemble
   fails with a reason indicating the `--enable-tail-call` flag/feature is unrecognized (older wabt) —
   mirror the existing `Error("wat2wasm not found") -> Nil` discipline so CI stays deterministic on
   toolchains without tail-call support. Drive it for both a `return_call` and a `return_call_indirect`
   module. This is the "where feasible" equivalence; tests 1-5 are the unconditional backstop.

**Adversarial / must-reject (syntactic fail-closed only):**
7. **Truncated `return_call`:** a byte stream ending on the `0x12` opcode with no following funcidx bytes
   decodes to `Error(ast.Truncated)` (via `idx_instr` → `decode_u_n`) — never a silent success. (Craft as
   a minimal code-section body so `decode.decode` reaches the truncation.)
8. **Truncated `return_call_indirect`:** `0x13` with a typeidx but a missing tableidx → `Error(Truncated)`
   — proves the second immediate is genuinely required (the anti-swap two-read path, not `idx_instr`).
9. **WAT missing operand:** `(func (return_call))` (no func id) → `Error(UnexpectedEof(_))` from
   `one_idx`; `(func (return_call $nope))` referencing an undefined func id → the parser's
   unresolved-reference error. Same for `return_call_indirect $undef_table`.
10. **Scope guard (Q8):** `(func (return_call_ref …))` — a *neighbouring* tail-call-with-typed-refs
    mnemonic that is **out of scope** — still returns `Error(UnknownMnemonic(_))` / `Unsupported(_)` from
    `unsupported_or_unknown`; the two additive arms did not accidentally swallow it. This guards the
    fall-through the additive edits sit next to.

---

## §6. Definition of Done (per [`../03-phase-workflow.md`](../03-phase-workflow.md) §9)

1. Spec-cited round-trip tests (§5) green, **including the truncation fail-closed cases (7-8) and the
   anti-swap ordering assertion (3)**; write any that would have caught a plausible bug as failing-first.
2. `///` / `//` doc comments updated on every function this unit touches — in particular the
   `call_indirect_instr` doc must state it now backs **both** `call_indirect` and `return_call_indirect`,
   and the new decode arms carry a comment citing the immediate identity with `0x10`/`0x11`. (No *new*
   public function is introduced; the refactored `call_indirect_instr` stays private.)
3. `gleam format --check src test` clean.
4. `gleam build` **zero warnings**.
5. This unit's suite passes; **default ingest is byte-identical** — the full `gleam test` stays green with
   no change to `decode_test` / `wat_test` (the `diff` differential corpus over non-tail-call modules is
   untouched, proving Q6).
6. `state.md` updated: Q13-02 done, additive-only, no frozen signature, no cross-file reach.

---

## §7. What it leaves (handoff to downstream)

- **Q13-03 (validate):** the real typing rule — pop the callee params (+ `i32` index and `FuncRef` table
  check for indirect), then **require the callee's result types to equal the current function's result
  types** (spec §return_call validation; reuse `TypeMismatch`), then `mark_unreachable`. **All
  `assert_invalid` result-mismatch fixtures live there, not here** — this unit deliberately accepts any
  *syntactically* well-formed `return_call*` regardless of types.
- **Q13-04 (lower):** the bottom-transfer lowering (`Return`-shape: build the node, `consume_dead` the
  tail, `end_or_else`; import split `f < ctx.imported`). Until it lands, the keystone's conservative-sound
  `lower` placeholder handles the AST nodes this unit now produces — so a full decode→lower of a
  `return_call` module already compiles and runs (as an ordinary call), just not yet in constant stack.
- **Q13-05 (emit_core):** genuine constant-stack tail emission + the `rt_table.call_indirect_lookup` seam.
- **Q13-06 (capstone):** vendoring `return_call.wast` / `return_call_indirect.wast` and the two EH files,
  the constant-stack corpus program, and re-measuring conformance. This unit ships **no** conformance
  wiring, corpus program, or `.wast` — only the two ingest paths those files travel through.
