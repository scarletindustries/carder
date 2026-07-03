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

const TRANSFORMS = [optionalTypedAccessFix];

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
writeFileSync(outFile, out.code);
console.error(`[codemod] applied ${TRANSFORMS.length} transform(s): ${inFile} -> ${outFile}`);
