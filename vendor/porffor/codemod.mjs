// codemod.mjs — POST-esbuild source transforms that rewrite JS constructs Porffor 0.61.13
// miscompiles when self-compiling its own bundle, into equivalent forms it handles.
//
// WHY POST-esbuild: esbuild re-parses to an AST and re-emits, which NORMALIZES away purely-syntactic
// fixes (e.g. `(a?.b)?.length` collapses back to `a?.b?.length` — same AST). So the codemod must run
// on the BUNDLE (after esbuild) and produce STRUCTURALLY-different code that esbuild can't fold back.
// Run with `--target=esnext` in esbuild so `?.`/`??` reach us intact.
//
// KNOWN CONSTRUCT #1 (found by bisection — see FINDINGS.md): a `?.length` (or optional computed
// access) whose base is ITSELF an optional chain — e.g. `func?.returns?.length`. Porffor's `.length`
// returns an i32; the double-optional short-circuit path is an f64 (undefined), so the merge emits a
// `type mismatch: expected i32, found f64`. This is the SOLE validation blocker (in codegen.js
// `generateCall`, 2 occurrences). Fix: hoist the chain base into a temp and guard the `.length`.
//
//   OBJ?.length   -->   ((_t) => _t == null ? undefined : _t.length)(OBJ)   // single-eval, general
//
// Add future transforms to TRANSFORMS as new self-compile constructs are discovered (the bisect.sh
// harness localizes them). Usage: `node codemod.mjs <in.js> <out.js>`.

import { readFileSync, writeFileSync } from 'node:fs';
import { transformSync } from '@babel/core';

/** Is this AST node an optional chain (its own short-circuit), i.e. `x?.y` / `x?.[y]` / `x?.()`? */
const isOptionalChain = (n) =>
  n &&
  (((n.type === 'OptionalMemberExpression' || n.type === 'OptionalCallExpression') && n.optional) ||
    // a non-optional link WHOSE object is an optional chain is still part of the chain
    ((n.type === 'OptionalMemberExpression' || n.type === 'OptionalCallExpression') &&
      isOptionalChain(n.object)) ||
    (n.type === 'MemberExpression' && isOptionalChain(n.object)));

/**
 * Transform #1: `<optional-chain>?.length` / `<optional-chain>?.[idx]` → a hoisted-temp guard.
 * Only fires when the accessed member is optional AND its base is itself an optional chain (the
 * exact Porffor miscompile). Single-evaluates the base (side-effect-safe).
 */
const optionalTypedAccessFix = ({ types: t }) => ({
  name: '2core-porffor-optional-typed-access',
  visitor: {
    OptionalMemberExpression(path) {
      const n = path.node;
      if (!n.optional) return; // the `?.` link itself must be optional
      if (!isOptionalChain(n.object)) return; // ...and its base must already be a chain
      // Only the accesses Porffor mistypes: `.length` (i32) or a computed index.
      const isLength = !n.computed && n.property.type === 'Identifier' && n.property.name === 'length';
      if (!isLength && !n.computed) return;
      const uid = path.scope.generateUidIdentifier('oc');
      const param = t.identifier(uid.name);
      const member = n.computed
        ? t.memberExpression(param, n.property, true)
        : t.memberExpression(param, t.identifier(n.property.name));
      // ((_oc) => _oc == null ? undefined : _oc.<member>)(<base>)
      const arrow = t.arrowFunctionExpression(
        [param],
        t.conditionalExpression(
          t.binaryExpression('==', t.identifier(uid.name), t.nullLiteral()),
          t.identifier('undefined'),
          member,
        ),
      );
      path.replaceWith(t.callExpression(arrow, [n.object]));
    },
  },
});

/**
 * Transform #2 (FINDINGS §8): `globalThis.X = …` does NOT make bare `X` readable in Porffor
 * (native: `globalThis.Prefs = {}` then bare `Prefs` throws "Prefs is not defined" — Porffor doesn't
 * link a globalThis property to a global binding). Porffor's own code sets globals via `globalThis.X`
 * (Prefs, precompile, pageSize, parser, …) and reads them BARE everywhere, so self-hosting breaks.
 * Fix: rewrite every `globalThis.X` member access to bare `X` and declare all such `X` as module-level
 * `var`s (prepended below), unifying reads and writes onto one binding. `process` is left alone — it is
 * a Node global handled by the stub prepended below, not a bundle-internal global.
 */
// Names that are ALSO a local var/let/const binding somewhere. Rewriting `globalThis.X` to bare `X`
// for such a name would collide with (or TDZ against) the local binding — e.g. assemble.js's
// `let importFuncs = globalThis.importFuncs = []` would become `let importFuncs = importFuncs = []`
// (a self-referential initializer that TDZs). We leave those as `globalThis.X` (Porffor still can't
// read them bare, but they are not on the console.log(1+2) probe path; the real fix is a
// generateIdent fallback to globalThis — FINDINGS §8). Prefs/precompile/etc. are pure globals and get
// rewritten. Collected in a first pass so the rewrite (second pass) can consult it.
const gtNames = new Set();
const rewriteGlobalThis = ({ types: t }) => ({
  name: '2core-rewrite-globalthis',
  visitor: {
    Program: {
      enter(path) {
        // Program.enter runs before child visitors, so collect ALL local var/let/const bindings up
        // front — then the MemberExpression visitor can safely consult the complete set.
        const localDecls = new Set();
        path.traverse({
          VariableDeclarator(p) {
            if (p.node.id.type === 'Identifier') localDecls.add(p.node.id.name);
          },
        });
        this.localDecls = localDecls;
      },
    },
    MemberExpression(path) {
      const n = path.node;
      if (n.computed || n.object.type !== 'Identifier' || n.object.name !== 'globalThis') return;
      if (n.property.type !== 'Identifier') return;
      const nm = n.property.name;
      if (nm === 'process') return;               // Node global — see the stub prepend
      if (this.localDecls?.has(nm)) return;       // also a local binding — leave as globalThis.X (FINDINGS §8)
      gtNames.add(nm);
      path.replaceWith(t.identifier(nm));
    },
  },
});

const TRANSFORMS = [optionalTypedAccessFix, rewriteGlobalThis];

const [, , inFile, outFile] = process.argv;
if (!inFile || !outFile) {
  console.error('usage: node codemod.mjs <in.js> <out.js>');
  process.exit(2);
}
const src = readFileSync(inFile, 'utf8');
const out = transformSync(src, {
  configFile: false,
  babelrc: false,
  compact: false,
  plugins: TRANSFORMS,
  sourceType: 'module',
});

// Prepended, in order, BEFORE all bundled module init (which runs before entry.js's body):
//  - a `process` stub: Porffor's Prefs/CLI code reads process.argv / process.stdout at init; the
//    self-hosted compiler has no Node `process`, so provide a harmless one (FINDINGS §8). Falls back
//    to the real process under Node so the build-time sanity probe still works.
//  - `var` declarations for every global that was set via `globalThis.X` (see transform #2).
const processStub =
  'var process = globalThis.process || { argv: [], env: {}, platform: "wasm", version: "", ' +
  'stdout: { write: () => {}, isTTY: false }, on: () => {}, exit: () => {} };\n';
const gtDecls = gtNames.size ? `var ${[...gtNames].join(', ')};\n` : '';
writeFileSync(outFile, processStub + gtDecls + out.code);
console.error(`[codemod] applied ${TRANSFORMS.length} transform(s) + process stub + ${gtNames.size} bare-globals: ${inFile} -> ${outFile}`);
