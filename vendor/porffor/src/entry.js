// The pure, Node-free entry point for the self-hosted Porffor compiler.
//
// Porffor's `compile(code)` (compiler/index.js default export) already takes a JS source string
// and returns `{ wasm, funcs, globals, ... }` where `out.wasm` is the assembled Wasm byte array.
// The only Node coupling (`node:fs` / `execSync`, and the `2c.js` `eval`) lives in CLI output paths
// that a pure `compile(code)` call never reaches — build.sh strips them (see scripts/apply-patches.sh).
//
// esbuild bundles this + acorn + the whole compiler into ONE self-contained ESM file with no bare
// imports, which Porffor can then compile to `porffor.wasm` (self-hosting). Bundle with
// `--target=esnext` so esbuild does NOT downlevel `?.`/`??` — Porffor supports them natively, and
// downleveling both changes what Porffor sees AND erases the codemod's structural fixes.
//
// `cyclone`/`pgo` are optional optimizer passes disabled here to keep the pure path minimal and
// deterministic (they are not needed for correct output; see FINDINGS.md).

globalThis.Prefs = globalThis.Prefs || { cyclone: false, pgo: false };

import compile from '../upstream/compiler/index.js';

/**
 * Compile a JS source string to a Wasm binary, entirely in-process (no fs, no Node).
 * @param {string} code  JS source.
 * @param {boolean} module  parse as an ES module (default true).
 * @returns {Uint8Array}  the compiled Wasm bytes (magic `\0asm`).
 */
export const compileJS = (code, module = true) => compile(code, module).wasm;

// A self-compile smoke probe: when the bundle is run (in Node, or in-Wasm once self-hosted), this
// compiles a trivial program and prints the resulting byte length — proof the compiler functions.
if (globalThis.__PORFFOR_SELFHOST_PROBE__ !== false) {
  try {
    const bytes = compileJS('console.log(1 + 2);');
    // eslint-disable-next-line no-console
    console.log('probe_len=' + bytes.length + ' magic_ok=' + (bytes[0] === 0 && bytes[1] === 97));
  } catch (e) {
    // eslint-disable-next-line no-console
    console.log('probe_error=' + (e && e.message));
  }
}
