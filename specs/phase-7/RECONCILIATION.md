# Phase 7 — Canonical reconciliation decisions (AUTHORITATIVE)

> The canonical decisions block for Phase 7, output of the 3-lens adversarial critique folded back by
> the EM. **Where any unit doc (`01`–`10`) conflicts with a decision here, THIS WINS.** Read order for
> every implementer: [`00-overview.md`](00-overview.md) → [`PORFFOR-ABI-FINDINGS.md`](PORFFOR-ABI-FINDINGS.md)
> → **this file** → your unit doc. Decisions **T1–T14**; each names the units it patches. The critique
> caught **7 blockers + 10 majors** — the dominant themes: (a) the **legacy** EH encoding Porffor
> actually emits had no coherent owner, and (b) the EH AST/IR/rt_exn shapes were frozen 2–4 ways.
> Everything below was **empirically verified** (Porffor 0.61.13 + `wasm-tools` byte dumps + Porffor
> source `precompile.js`/`wrap.js`/`compiler/types.js`).

---

## T1 — The EH IR is INLINE-HANDLER shaped (legacy 1:1, modern via transfer, Core-Erlang 1:1)

The critique's biggest blocker: Porffor emits the **legacy** `try 0x06 / catch 0x07 / end 0x0B`
(inline-handler, no label), but the units froze a **modern label-branch** `CatchClause(on, label)` and
nobody normalized legacy → modern. **Resolution — freeze the IR inline-handler-shaped**, which maps
*both* encodings AND Core Erlang's `try…catch` (also inline-handler) with no branch-renumbering:

```gleam
// ir.gleam
Try(result: List(ValType), body: Expr, handlers: List(CatchHandler))     // was "TryTable"
pub type CatchHandler {
  CatchHandler(on: CatchTag, payload: List(String), exnref: Option(String), handler: Expr)
}
pub type CatchTag { OnTag(tag: String)  OnAll }     // tag by NAME (T4)
Throw(tag: String, args: List(Value))               // bottom, like Return
ThrowRef(exnref: Value)
```

- **Legacy WASM `try bt B catch x H end`** → `Try(bt, lower(B), [CatchHandler(OnTag(x), names, None,
  lower(H))])` — DIRECT; the handler is the inline legacy handler, the tag operands bound to fresh
  `names` the handler references. No restructuring, no branch renumbering.
- **Modern `try_table` catch clause → label** → `CatchHandler(on, names, exnref?, handler)` where
  `handler` is the transfer to the target frame: `Break(label, names++exnref)` for a block,
  `Continue(label, …)` for a loop, `Return(…)` for the function frame. **This resolves the
  "label-only clause loses the target-frame kind" major** (M4) — the handler is a full `Expr`, so
  lower picks Break/Continue/Return from the resolved frame kind. No Phase-7 scope limitation needed.
- **emit (06)** lowers `Try` → Core Erlang `try B of <Vs> -> <Vs> catch C:R:S -> <handler dispatch>`
  1:1 (Core Erlang's try is inline-handler — see T5). Legacy + modern share one emit path.

**Patches:** 01 (rename `TryTable`→`Try`; `CatchClause`→`CatchHandler` inline-handler shape; drop the
bare-label form), 02 (grammar-delta to the inline shape), 05 (lower BOTH legacy flat-stream and modern
`try_table` into `Try`; the structuring happens in lower exactly as for `block`/`if`), 06 (emit `Try`).

## T2 — decode + validate + lower each handle BOTH encodings; validate is fail-CLOSED-COMPLETE

Legacy is the **headline** path (every real Porffor module carries it), so it is not merely
"rejected" — it is fully supported through the pipeline (no separate normalization pass; T1's IR
absorbs both):
- **decode (03, owns AST5):** decode legacy (`try` 0x06 opener / `catch` 0x07 / `catch_all` 0x19 /
  `delegate` 0x18 / `rethrow` 0x09 / `end`) as flat-stream openers/markers (like `block`/`end`) AND
  modern (`throw` 0x08 / `throw_ref` 0x0A / `try_table` 0x1F + catch kinds 0x00–0x03 / `exnref` 0x69),
  plus the **tag section (id 13**, ranked between memory=5 and global=6 — spec-correct) + import/
  export-tag (desc 0x04). **AST5 shape is 03's, ONE field:** `ast.Tag(type_idx: Int)` (the 0x00
  attribute byte is checked-and-dropped), `ast.ImportTag(module, name, type_idx: Int)`, the catch type
  is `ast.Catch`, `ast.Throw(tag: Int)`. (M2/M3 — 04/05 conform to these names/arities.)
- **validate (04, AST-only):** type BOTH — modern (`throw`/`throw_ref` stack-polymorphic; `try_table`
  clause labels accept the tag params + optional exnref) AND **legacy** (`try` as a block-with-inline-
  catch-arms: body typed against the blocktype, each catch handler typed with the tag's params on the
  stack against the blocktype results). **Intercept EVERY EH `Instr` ctor before the `numeric_sig`
  fail-OPEN fallthrough** (the security hole — validate.gleam:1171/1993): a genuinely-unsupported form
  (e.g. `delegate` at depth 0) is `Error(Unsupported(_))`, never a silent no-op. `TypedModule` carries
  `tag_types: List(List(ast.ValType))` + `imported_tag_count` (AST-level — 04 imports no `twocore/ir`;
  M3). Extend the grep-assert to ALL EH arms.
- **lower (05):** structure the legacy flat-stream `try…catch…end` AND the modern `try_table` into the
  one inline-handler `Try` IR (T1); `Throw(tag: Int)` AST → `Throw(tag: String, args)` IR (name via
  `Module.tags`); the tag section → `Module.tags: List(TagDecl)` with `TagDecl(name, params:
  List(ValType))` (M1 — drop the `FuncType` form; validate proved results empty). Consume
  `List(List(ast.ValType))`, not `List(ir.FuncType)`.

## T3 — rt_exn call ABI is 07's implementable head list (ONE frozen set)

`«RT-EXN-SIG»` was frozen three ways. **Adopt 07's set** (the only implementable one); 06 emits
exactly these, 01 freezes them:
```gleam
// runtime/rt_exn.gleam
pub fn throw_exn(tag_id: Int, payload: List(Dynamic)) -> a        // raises {wasm_exn, TagId, Payload}
pub fn match_tag(reason: Dynamic, tag_id: Int) -> Result(List(Dynamic), Nil)  // ok(payload) | Error
pub fn is_wasm_exn(reason: Dynamic) -> Bool                       // for catch_all (exn, not a trap)
pub fn reraise(class, reason, stack) -> a                          // erlang:raise/3, preserves stack
pub fn capture_exnref(reason: Dynamic) -> Dynamic                  // -> {ref_exn, Reason} (T9)
pub fn throw_ref(exnref: Dynamic) -> a
pub fn is_exnref(x: Dynamic) -> Bool
```
Drop 06's `throw`/`t_throw`/`rethrow`/`capture` names. **Patches:** 01 (freeze this set), 06 (emit it),
07 (implement it).

## T4 — TagId is a module-local `Int`; throw + catch route through the ONE identity

Tag identity was frozen three ways (throw-site vs catch-site diverged → the catch `case` never
matches → JS `try/catch` never catches). **Pin a module-local `Int`** (the tag's index; single-module
Porffor scope — measured: Porffor exports its one tag, imports none). `Throw` lowers to
`rt_exn.throw_exn(tag_index, payload)`; the catch dispatches on the same `tag_index` via
`rt_exn.match_tag(Reason, tag_index)`. Drop 06's `{module_name, idx}` tuple + the unowned
`Ctx.module_name`. A qualified `{module, idx}`/opaque token is deferred to a cross-module-EH milestone
(Porffor-inert). **Patches:** 01/06/07.

## T5 — The `CTry` Core-Erlang AST node is owned by P7-06 (core_erlang has no `try` today)

`core_erlang.gleam` deliberately has no `try` node (verified — `core_printer.print_expr` is total over
the current set). Growing `CExpr` is a real cross-file reach. **Owner: P7-06** — it adds the `CTry`
`CExpr` variant, the `core_printer` arm (the `compile:from_core`-accepted form is the parenthesized
**`try Arg of <Vs> -> Body catch <Class, Reason, Stacktrace> -> Handler`** — three catch pattern vars,
NO Erlang-style `end`, M-minor), and `core_lint` acceptance. The keystone's EH emit arms stay
`UnsupportedNode` (byte-identical). **Patches:** 01 (drop the "keystone adds CTry" wording; keep
UnsupportedNode arms), 06 (owns CTry + printer + lint; freeze one spelling).

## T6 — EH ships CELL-ONLY; Threaded + EH is a categorized-unsupported skip (honest)

Threaded-state-through-throw was frozen incompatibly (06's `t_throw`/4-tuple vs 01/07's 3-tuple
no-state). Both 06 and 07 note the JS/EH path ships under Cell. **Pin: EH is Cell-only** (the Safe
default; the JS/Porffor path is Cell). The thrown term is the **3-tuple `{wasm_exn, TagId, Payload}`**
(no state). **Delete 06's `t_throw`/4-tuple/thrown-through-record design + its e2e #6.** Threaded + EH
is a documented, categorized-unsupported combination (like prior tier edges). **Patches:** 01 (3-tuple,
no state param), 06 (delete t_throw), 07 (Cell-only bodies), 10 (categorize Threaded+EH).

## T7 — The catch term shape lives ONLY in rt_exn (the binding chokepoint); emit calls the helpers

Catch lowering was frozen two ways (06 inlined the `{wasm_exn,…}` literal pattern; 07 exported
`match_tag`/`is_wasm_exn`). **Pin 07's helper-call form** (D3b chokepoint — the `{wasm_exn,…}` term
shape lives in exactly one module, `rt_exn`, never smeared across emitted Core Erlang): emit lowers a
catch as `case rt_exn:match_tag(Reason, T) of {ok, P} -> <handler with P> ; _ -> …` and a `catch_all`
via `case rt_exn:is_wasm_exn(Reason) of 'true' -> … ; 'false' -> rt_exn:reraise(C,R,S) end`. The
load-bearing rule **`catch_all` catches WASM exceptions but NOT traps** (a `MemoryOutOfBounds` trap or
`FuelExhausted` must PROPAGATE through `catch_all`) is enforced by `is_wasm_exn` matching only
`{wasm_exn,…}`, never `{wasm_trap,…}`. Rewrite 06's goldens to assert the helper calls. **Patches:**
06/07.

## T8 — Uncaught exceptions surface as a DISTINCT run-ABI outcome (not a trap, no new TrapReason)

An uncaught WASM exception must be observable distinctly from a trap (`assert_exception` ≠
`assert_trap`). **Add `UncaughtException(tag_id: Int, payload: List(Int))` to `pipeline.RunResult`**
(today `Returned | Trapped`) — NOT a `TrapReason` (S8 posture holds; the trap match tables stay
untouched). The top-level run-ABI catches the `{wasm_exn,…}` class and renders it as `UncaughtException`;
a `{wasm_trap,…}` stays `Trapped`. **Owner: P7-06** (the `pipeline.gleam` edit + the throw-class catch
arm). Correct 06's "ordinary trapped/failed result" wording. **Patches:** 06 (owns), 01/07/10 (consume
the distinct outcome).

## T9 — `exnref` is a reason-only forge-proof box; classify_ref gains an ExnRef arm (Porffor-inert)

`exnref` (a reftype: `ValType.TExnRef` + `RefType.ExnRef`, reusing the forge-proof `rt_ref` model) is
a caught-exception handle. **Pin the reason-only box `{ref_exn, Reason}`** (not the `{Class,Reason,
Stk}` triple — WASM has no observable stack, so `throw_ref` is a fresh `erlang:throw` of the captured
reason; simpler + spec-faithful). `capture_exnref(reason)` is 1-arg. **07 adds the `RefKind.ExnRef`
arm to `rt_ref.classify_ref`** (overriding its consumed-never-edited stance — a `{ref_exn,_}` would
else misclassify as funcref). **This entire surface (exnref/throw_ref/catch_ref/catch_all_ref) is
Porffor-INERT** (Porffor never emits it) — it is **spec-conformance surface only**, bounded by which
EH `.wast` are `wast2json`-able at the pin. **Patches:** 01 (box shape + capture arity), 07 (bodies +
classify_ref arm), 06 (throw_ref = reraise the captured reason).

## T10 — The Porffor entry export is the fixed `"m"`; memory `"$"`; tags `"0","1",…`

Frozen two ways (fixed `"m"` vs the JS basename). **MEASURED: it is always `"m"`** (Porffor's
top-level `#main`), NOT the basename (verified on 8+ programs incl. a uniquely-named `wombat.js`).
**Pin: entry export `"m"`, memory `"$"`, tag exports `"0","1",…`.** Keep 09's robust fallback (the
sole function export that is neither a tag `"0"` nor the memory `"$"`) as the resolver — it always
resolves to `"m"`. Delete 09's basename claim. **Patches:** 08/09/10.

## T11 — The Porffor intrinsic set is FOUR (`a`/`b`/`c`/`d`), verified against Porffor source

Under-enumerated as `a`/`b`. **MEASURED (Porffor `precompile.js`/`wrap.js` register exactly four, in
order):** `a` = `print` (`i => print(i.toString())` — a number/scalar printer), `b` = `printChar`
(`i => print(String.fromCharCode(i))`), `c` / `d` = the time/perf intrinsics (`Date.now`/
`performance.now`-family). The Porffor shim (08) implements **all four**, build-fixed (literal `case`,
no `apply/3`, D3a). **Output is IN-BAND + ANSI-colored** (measured: `console.log(42)` →
`\x1b[33m42\x1b[0m\n` — the number wrapped in ANSI yellow via `printChar`) — the harness (09) captures
the `printChar`/`print` byte stream and **compares against `porf run`'s identical ANSI output** (T13),
so the color is matched, not stripped-and-guessed. **Type tags (verified vs `compiler/types.js`):**
undefined 0x00, number 0x01, boolean 0x02, string 0x43 (0x03 | 0x40 length-flag), bytestring 0xC3.
**Patches:** 08 (four intrinsics + tags), 09/10/ABI-findings (four, not two).

## T12 — Prove the EH-free JS subset EARLY (de-risk the headline); scope run results to scalars

**MEASURED: trivial JS is EH-free and runs on Phase-6 code TODAY** — `console.log(42)`,
`console.log("hello")`, `console.log(Math.sqrt(16))`, top-level `2+3` compile with **zero tags / zero
throws** (`wasm-tools validate` passes at the wasm-2.0 baseline, no `legacy-exceptions`). So **the
Porffor shim (08) proves "JS on the BEAM" on the EH-free subset immediately** — independent of the EH
pipeline (03–07) — a valuable de-risk + an early headline. Only programs with runtime type errors /
`try/catch` need EH. **Correct the DAG/09/08** ("no JS runs until EH" is false). **Implementation
order:** 01 keystone → **08 shim (proves EH-free JS e2e)** → 03/04/05 EH-frontend → 07 rt_exn → 06 emit
(EH e2e) → 02 .ir → 09 full JS corpus → 10 capstone. **run result scope (M9):** `run_porffor` returns
**scalar** results (number/boolean/undefined — decoded from the `(f64, i32)` pair by the type tag);
**console output is the primary observable** (captured in-band, no heap read needed for `console.log`
programs). **Heap decode (string/object/array results) is best-effort/deferred** — the `console.log`
of a string still works (Porffor's `printChar` emits the bytes in-band). The console-drain FFI is owned
by **08**; a routed instance-memory-read FFI (for scalar-pointer decode) is 08's too, scoped small.

## T13 — `porf run` is the primary differential oracle (fair, non-circular); Node is secondary

**Verified: `porf run` is V8 executing the SAME `.wasm` 2core consumes** (Porffor's `wrap.js`
instantiates it via `WebAssembly` with the four intrinsics) — a **fair, non-circular** oracle (it
tests the same compiled artifact, so a divergence is a 2core bug, not a compiler difference). **Judge
JS results against `porf run` first** (byte-identical ANSI output expected); use Node only as a
sanity secondary, tolerating known Porffor-vs-Node formatting divergences (measured: `console.log(-0)`
→ Porffor `"0"` vs Node `"-0"`; Porffor's `print` = `i.toString()`, no `util.inspect` special-casing).
A `porf`-vs-`node` divergence is **not** a 2core failure — it is a categorized note. **Patches:** 09
(oracle = `porf run`), 10.

## T14 — Scope honesty (unchanged intent, sharpened)

The **headline** (T12) is EH-free + EH JS programs running on the BEAM byte-identically to `porf run`,
**measured**, bounded by Porffor's ~⅓-ECMA coverage. **EH is Cell-only** (T6). The **modern EH surface
(exnref/throw_ref/catch_ref/catch_all_ref/try_table)** is spec-conformance-only (Porffor-inert, T9) —
its greenness is bounded by `wast2json`-ability of the EH `.wast` at the pin (measure, don't promise).
**No new TrapReason** (T8). No WASI/DOM. Threaded+EH, cross-module tags, and heap-typed run results are
categorized deferrals. The capstone claim is **"JS on the BEAM via Porffor (the measured Porffor-
compilable subset)"**, never "full JS".

---

## What did NOT change (the critique confirmed SOUND — implement as specced)

- **Every EH opcode/section/type byte is correct** (verified vs Porffor 0.61.13 + `wasm-tools`):
  legacy `try` 0x06 / `catch` 0x07 / `throw` 0x08 / `rethrow` 0x09 / `delegate` 0x18 / `catch_all`
  0x19 / `end` 0x0B; modern `throw_ref` 0x0A / `try_table` 0x1F + catch kinds 0x00–0x03; `exnref` =
  0x69; tag section id 13 ranked memory(5) < TAG < global(6); import/export-tag desc 0x04.
- **The EH→BEAM mapping thesis is sound + consistent**: `(tag)`/`throw`/`try(_table)` → a build-
  controlled `{wasm_exn, TagId, Payload}` term + a native Core-Erlang `try…catch`; `catch_all` catches
  exceptions-not-traps; D3a preserved (no `apply`/`binary_to_atom`/module-name construction);
  constant-space + preemption preserved across a throw (native BEAM unwinding); forge-proof exnref box;
  **byte-identity for tag-free modules** (tags:[] ⇒ EH arms unreached).
- **The value ABI + shim semantics are fully verified vs Porffor source**: the four intrinsics + their
  bodies; the type-tag constants; the string/bytestring memory layouts; in-band ANSI output; number
  formatting (`0.1+0.2`→`0.30000000000000004`, `1e21`→`1e+21`); `porf run` as a fair oracle; and **the
  core premise — beyond EH, Phase 6 covers everything Porffor emits** (measured on a real
  `[1,2,3].map(x=>x*2).join(',')` program).
- **No new TrapReason** (a WASM exception is a distinct term class, not a trap).

## Scope & DAG deltas (summary)

- **Unit count stays 10.** Implementation order (T12): 01 → **08 (early EH-free headline)** → 03 → 04
  → 05 → 07 → 06 → 02 → 09 → 10.
- **IR:** inline-handler `Try`/`CatchHandler`/`Throw(tag:String)`/`ThrowRef` (T1); `Module.tags` +
  `TagDecl(name, params)`; `TExnRef`/`RefKind.ExnRef` (T9). New `pipeline.RunResult.UncaughtException`
  (T8). New Core-AST `CTry` (owner 06, T5). New `rt_exn.gleam` (07, T3). No new TrapReason.
- **EH is Cell-only** (T6); the modern EH surface is spec-conformance-only (T9); heap-typed run results
  + Threaded+EH + cross-module tags are categorized deferrals (T14).
- **Porffor:** entry `"m"` / mem `"$"` / tags `"0"…` (T10); four intrinsics a/b/c/d (T11); `porf run`
  the oracle (T13); scalar+console results (T12).
