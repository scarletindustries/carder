// instrument-sites.mjs — find WHICH construction site (regex, TypedArray, or console.*) throws in the
// self-hosted bundle, using baked string-literal markers (safe from Porffor's at-scale string-concat
// corruption). The last "<<SITE n …>>" printed before the crash is the culprit.
//
// Regex literals are especially sneaky: Porffor lowers `/pat/flags` into a runtime `RegExp("pat",
// "flags")` call, so a plain `new RegExp` wrapper never catches them — this transform rewrites BOTH
// `new RegExp(...)` AND regex literals. It also wraps TypedArray ctors and console.* calls.
//
// Usage (run from vendor/porffor):
//   node diagnostics/instrument-sites.mjs regex dist/porffor.compiler.js /tmp/instr.js
//   npx porffor run --module /tmp/instr.js 2>&1 | grep -oE "<<SITE [0-9]+[^>]*>>" | tail -3
//   cat /tmp/instr.js.sites.txt   # index -> what each site is
//
// modes: regex | typedarray | console   (default: regex)
import { readFileSync, writeFileSync } from 'node:fs';
import { transformSync } from '@babel/core';

const MODE = process.argv[2] || 'regex';
const TA = new Set(['Uint8Array','Uint16Array','Uint32Array','Int8Array','Int16Array','Int32Array','Float32Array','Float64Array','Uint8ClampedArray']);
let counter = 0;
const sites = [];

const wrap = (t, node, label) => {
  const idx = counter++;
  sites.push(`${idx}: ${label}`);
  // (console.log("<<SITE idx label>>"), <node>)   — marker runs first, then the real construction
  return t.sequenceExpression([
    t.callExpression(t.memberExpression(t.identifier('console'), t.identifier('log')),
      [t.stringLiteral(`<<SITE ${idx} ${label}>>`)]),
    node,
  ]);
};

const plugin = ({ types: t }) => ({
  name: 'instrument-sites',
  visitor: {
    NewExpression(path) {
      const n = path.node, c = n.callee;
      if (c.type !== 'Identifier') return;
      if (MODE === 'regex' && c.name === 'RegExp') { path.replaceWith(wrap(t, n, `newRegExp/${n.arguments.length}`)); path.skip(); }
      else if (MODE === 'typedarray' && TA.has(c.name)) { path.replaceWith(wrap(t, n, c.name)); path.skip(); }
    },
    RegExpLiteral(path) {
      if (MODE !== 'regex') return;
      const n = path.node;
      const re = t.newExpression(t.identifier('RegExp'), [t.stringLiteral(n.pattern), t.stringLiteral(n.flags || '')]);
      path.replaceWith(wrap(t, re, `/lit/${n.flags || ''}`)); path.skip();
    },
    CallExpression(path) {
      if (MODE !== 'console') return;
      const c = path.node.callee;
      if (c.type === 'MemberExpression' && c.object.type === 'Identifier' && c.object.name === 'console' &&
          c.property.type === 'Identifier' && !path.node.__m) {
        path.node.__m = true;
        path.replaceWith(wrap(t, path.node, `console.${c.property.name}`)); path.skip();
      }
    },
  },
});

const [, , , inFile, outFile] = process.argv;
if (!inFile || !outFile) { console.error('usage: node instrument-sites.mjs <regex|typedarray|console> <bundle.js> <out.js>'); process.exit(2); }
const out = transformSync(readFileSync(inFile, 'utf8'),
  { configFile: false, babelrc: false, compact: false, plugins: [plugin], sourceType: 'module' });
writeFileSync(outFile, out.code);
writeFileSync(outFile + '.sites.txt', sites.join('\n'));
console.error(`[instrument-sites:${MODE}] wrapped ${counter} sites -> ${outFile}`);
