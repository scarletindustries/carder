# Diagnostics — how to localize a self-hosting `[run]` failure

`[run]` failures are *semantic* self-compile bugs: the wasm validates but mis-runs, and there is no
validator to point at the fault. These are the techniques that have worked (each found a real bug —
see `../FINDINGS.md`). They all exploit one fact: **`console.log` of a plain ASCII string literal
still works even at bundle scale, and flushes before an uncaught throw.** So baked string-literal
markers survive where almost nothing else does.

## The golden rule: BAKE markers, never build them at runtime

At the 26 MB bundle scale Porffor miscompiles `"prefix" + someNumber` string concatenation into
**garbage** (a symptom of the same memory/string corruption you're chasing). So a marker must be a
single string literal decided at transform time — `console.log("<<X 42>>")`, never
`console.log("<<X " + i + ">>")`. Every script here obeys this.

## Tools (run from `vendor/porffor/` so `@babel/core` resolves)

| Script | Finds |
|---|---|
| `instrument-init.mjs` | which **top-level module-init statement** throws |
| `instrument-sites.mjs <regex\|typedarray\|console>` | which **construction site** throws |
| `scale-test.mjs <N>` | function-**count** thresholds, in a fast loop (no bundle rebuild) |

Each `instrument-*` writes an instrumented copy; run it with `npx porffor run --module <copy>` and
read the LAST marker before the crash. `<name>.sites.txt` maps marker index → source construct.

## The `wrap.js read()` clamp trick (unmask a hidden thrown error)

When `porffor run` dies with `RangeError: Invalid typed array length: <huge>`, the wasm actually
**threw an exception** and Porffor's value-conversion glue is crashing while reading the thrown
Error's (corrupted) `.message`. To see the REAL error, temporarily edit the **tool's**
`compiler/wrap.js` `read()` (locate via `find ~/.npm -type d -name porffor`) to clamp absurd lengths:

```js
const read = (ta, memory, ptr, length) => {
  if (length > 100000000 || length < 0) { console.error('[diag] clamp', {ta:ta.name, ptr, length}); length = 64; }
  if (ta === Uint8Array) return new Uint8Array(memory.buffer, ptr, length);
  return new ta(memory.buffer.slice(ptr, ptr + length * ta.BYTES_PER_ELEMENT), 0, length);
};
```

Now `porffor run` prints the real thrown error type (e.g. `TypeError`) — enough to know the *kind* of
fault even if its message string is itself garbled. **Restore `wrap.js` afterwards** (`git`-clean it
or keep a `.bak`); it is the shared npx install.

## General loop

1. `instrument-init.mjs` → is it module init or the actual compile? which statement?
2. If a construction throws, `instrument-sites.mjs` → which regex / typed-array / console site?
3. Reproduce the construct **in isolation** with `npx porffor run --module tiny.js`. If it works
   isolated but fails in the bundle, it's **scale-dependent** → use `scale-test.mjs` (or add data
   size / function count) to find the threshold, which usually points at a Porffor constant/region.
4. Probe suspicious values with **booleans/typeof** (`console.log(x === undefined)`), not string
   interpolation — booleans print cleanly, corrupted strings do not.
5. Fix in BOTH Porffor copies (see FINDINGS §7b): `apply-patches.sh` (vendored) + `patch-build-tool.sh`
   (npx tool). Re-run `./build.sh && ./selfhost-check.sh`.
