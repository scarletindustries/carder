# lambda-lift — an experiment to work around Porffor's missing closures

**Status: partial. It advances `[run]` but does NOT reach GREEN — see "The ceiling" below.**

Porffor 0.61.13 has no closures that capture enclosing-function locals/parameters (FINDINGS §8b) —
only closures over **module globals** work. The Porffor compiler uses capturing closures pervasively,
so self-hosting stalls at the first one exercised (`inv`'s `.reduce` callback at init stmt ~703).

This directory holds a **standalone, opt-in** codemod that works around that by *globalizing* captured
variables. It is deliberately kept OUT of the main build (`build.sh`/`codemod.mjs`) so it is trivial to
drop or wire in later.

## Mechanism

For each function `F`, find every param/local that a **nested** function reads or writes (a real
capture), and promote it to a fresh module global `__ll$N`:

```js
var inv = (obj, keyMap) => Object.keys(obj).reduce((acc, x2) => { acc[keyMap(obj[x2])] = x2; … }, {});
// becomes:
var __ll$0, __ll$1;
var inv = (obj, keyMap) => {
  var __ll$0$s = __ll$0, __ll$1$s = __ll$1;      // save (recursion/reentrancy safe)
  __ll$0 = obj; __ll$1 = keyMap;                 // seed the globals from the params
  var __r = Object.keys(__ll$0).reduce((acc, x2) => { acc[__ll$1(__ll$0[x2])] = x2; … }, {});
  __ll$0 = __ll$0$s; __ll$1 = __ll$1$s;          // restore at every exit
  return __r;
};
```

The nested callback now reads module globals (which Porffor's closures CAN do). Save/restore at F's
entry/every-return makes it correct across recursion. (Porffor's `try/finally` + closure is broken, so
restores are plain assignments before each `return`, not a `finally`.)

Enabling facts (all verified natively): `.bind` is BROKEN in Porffor (so no partial-application), but
module-global closures + plain save/restore across recursion WORK.

## The ceiling (why it doesn't finish) ⛔

Globalization is only sound for **non-escaping** closures — ones that run synchronously within F's
dynamic extent (array-method callbacks: `.reduce`/`.map`/`.filter`/…). An **escaping** closure — stored
and called after F returns — would read a global that F already restored. The compiler has MANY escaping
closures that fundamentally CANNOT be lifted, e.g. `comptime`'s property-descriptor setter:

```js
const comptime = (name, returnType, comptime2) => {
  Object.defineProperty(_, name, { set(x) { x.comptime = comptime2; … } }); // setter outlives comptime()
};
```

The transform detects and **skips** escaping closures (returned/assigned/stored in an object or array
literal). On the current bundle: **~6 non-escaping param captures are safely globalized, ~66 escape and
are skipped.** Globalizing `inv` advances `[run]` past the init `keyMap` wall and into actual
compilation (`compileJS` now runs), where it hits the next capturing closure — a `this`-capture
(esbuild's `this$1`), then the escaping ones. Those need REAL closures; no codemod can eliminate them.

**Conclusion:** lambda-lifting extends how far the self-hosted compiler runs, but it is not a complete
path to `[run]` GREEN. Real closure support in Porffor (or a newer Porffor) is required for the escaping
closures. This experiment is preserved so that partial progress and the exact ceiling are reproducible.

## Usage

```bash
# apply to the built bundle (run build.sh first), then run it:
node lambda-lift/lambda-lift.mjs dist/porffor.compiler.js /tmp/lifted.js
npx porffor run --module /tmp/lifted.js        # advances past keyMap; then hits this$1 capture
node /tmp/lifted.js                            # Node sanity: must still print probe_len (correctness oracle)
```

Env knobs (debugging): `LL_LOCALS=1` also globalize simple local vars (unsound if an init depends on an
earlier decl — off by default); `LL_DEBUG=1` log each globalized slot; `LL_MAX`/`LL_MIN` limit slots
(binary-search a bad one against the Node oracle).

## Wiring into the build later

To make it part of the chain, insert a step in `build.sh` after the codemod:
`node lambda-lift/lambda-lift.mjs "$OUT" "$OUT"` (in-place). Do this ONLY once it is a net win and the
Node sanity probe still passes — today it advances `[run]` but does not make it GREEN, so it is left
opt-in. `apply-lambda-lift.sh` in this dir does exactly that in-place transform for convenience.
