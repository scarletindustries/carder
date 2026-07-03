# Phase 7 — Empirical Porffor-ABI findings (EM homework, measured — not assumed)

> These are **measured** facts from compiling real JS through **Porffor 0.61.13** (`npx porffor wasm
> foo.js foo.wasm`) and inspecting the output with `wasm-tools`. They are the load-bearing input to
> the Phase-7 scope. The scoping agents refine the fine detail (esp. the exact identity of the two
> intrinsic imports and the EH opcode bytes) against Porffor's source + more probes. A sample is
> committed at [`porffor-add-sample.wasm`](porffor-add-sample.wasm).

## What Porffor emits (stable across `hello`/`add`/`loop`/`str`/`rich` probes)

**The value ABI — every JS value is a `(f64, i32)` pair.** The `f64` is the value (a JS number
directly; for objects/strings/arrays, an i32 pointer into linear memory, carried in the f64); the
`i32` is a **type tag** (number / string / object / boolean / undefined / function / …). So a JS
function `(a, b) => …` compiles to a Wasm function of type `(param f64 i32 f64 i32) (result f64 i32)`
— **multi-value** in and out. This is Porffor's "typed values" representation (no NaN-boxing).

**Imports — a tiny, treeshaken intrinsic set.** Every probe imports exactly **two** host functions,
`(import "" "a" (func (param f64)))` and `(import "" "b" (func (param f64)))` — Porffor's builtin
console/IO primitives (its `print`/`printChar`-family; treeshaken to what the program uses). The
Porffor-ABI host shim must provide these (and any others a wider JS corpus pulls in — the scoping
agents enumerate the full set by probing more builtins). Module name is `""`.

**WASM features Porffor uses — ALL already covered by 2core EXCEPT exception handling:**

| Feature | Porffor uses it | 2core status |
|---|---|---|
| multi-value | ✓ (every fn `(result f64 i32)`) | ✓ Phase 1 |
| `call_indirect` + `funcref` | ✓ (8–9× — JS first-class fns / methods) | ✓ Phase 2 / 5 |
| bulk memory (`memory.copy`) | ✓ (6–7×) | ✓ Phase 5 |
| **v128 / SIMD** | ✓ (16× — string/memory ops) | ✓ **Phase 6** |
| **exception handling** (`(tag)` + `throw` + **legacy `try`/`catch`/`end`**) | ✓ (**64× throw** in a trivial program; a `(tag (param f64 i32))` carrying the thrown JS value; the **legacy block-form `try`/`catch`** for JS `try/catch` — RE-MEASURED: Porffor emits the LEGACY EH encoding `try`=0x06/`catch`=0x07/`throw`=0x08/`end`=0x0B, NOT the modern `try_table`; `wasm-tools validate` needs `--features=legacy-exceptions`) | ✗ **NOT BUILT — the gate** |
| GC (`struct`/`array`/`i31`/typed refs) | ✗ (confirmed empty — Porffor stays in core+common, §8.2) | ✗ (deferred; **not needed**) |

**Exception handling is the single missing WASM feature.** Porffor throws pervasively (every JS
error path / type check → a `throw` of a `(tag (param f64 i32))` carrying the thrown JS value); `try/
catch` JS → the **legacy block-form `try`/`catch`/`end`** (RE-MEASURED — Porffor uses the *legacy*
EH encoding, not `try_table`; and across every probe it emits exactly ONE `(tag (param f64 i32))`,
pervasive `throw`, and `try`/`catch` — **never** `catch_all`/`catch_ref`/`delegate`/`rethrow`/
`throw_ref`/`try_table`/`exnref`). Both `--exception-mode=stack` (default) and `lut` still emit tag/
throw/catch — there is **no Porffor mode that avoids WASM EH**. So *JS on the BEAM is gated on WASM
exception handling* — specifically **tags + `throw` + legacy `try`/`catch`**. **IR consequence (S-level):
freeze the EH IR encoding-neutral** — legacy (Porffor's headline path) and modern (`try_table`, for
the spec `.wast`) lower onto the SAME IR nodes (`Throw`/`TryTable`/`ThrowRef`); `throw_ref`/`exnref`/
`catch_all` are **spec-conformance surface only**, not Porffor-critical.

## The elegant fit — WASM EH maps onto BEAM-native exceptions

The BEAM has first-class exceptions (`throw`/`catch`, `error`/`raise`, `try…catch`). WASM EH lowers
onto them directly, exactly as the platform's thesis intends (compile-to-Erlang gives us the BEAM's
machinery for free — like tail-calls → BEAM tail calls, preemption → the scheduler):
- a WASM **`(tag)`** → a distinguishable BEAM exception term (e.g. `{wasm_exn, TagId, Payload}`);
- **`throw <tag>`** → a BEAM `throw`/`error` of that term;
- **`try_table` / `catch`** → a BEAM `try … catch` that matches the tag and binds the payload,
  re-raising a non-matching exception (structured, spec-faithful unwinding);
- constant-space + preemption are preserved (the BEAM's exception unwinding is native).

## Scope consequence (for the overview)

Phase 7 = **WASM exception handling (→ BEAM exceptions)** + **the Porffor-ABI `rt_host` shim** +
**a JS-subset conformance harness** (Porffor JS→WASM → `fe_wasm` → BEAM → check the JS result),
bounded by Porffor's experimental JS coverage (~⅓ of ECMA-262, §8.2). The headline: *a real Porffor-
compiled JS program runs on the BEAM via 2core.* EH is the load-bearing engine feature; everything
else Porffor needs already exists after Phase 6.
