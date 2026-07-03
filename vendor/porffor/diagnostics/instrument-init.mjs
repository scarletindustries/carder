// instrument-init.mjs — bracket WHICH top-level module-init statement throws in the self-hosted bundle.
//
// Inserts a baked `console.log("<<INIT n>>")` marker before every top-level statement. Run the output
// with `porffor run`; the LAST "<<INIT n>>" printed before the crash is the statement that threw
// (marker n printed, marker n+1 did not => statement n is the culprit). Then locate statement n in the
// output file to read it. This is how the `Position.prototype` = undefined bug (FINDINGS §7) was found.
//
// Usage (run from vendor/porffor so @babel/core resolves):
//   node diagnostics/instrument-init.mjs dist/porffor.compiler.js /tmp/instr-init.js
//   npx porffor run --module /tmp/instr-init.js 2>&1 | grep -oE "<<INIT [0-9]+>>" | tail -3
//   # then find statement N:
//   grep -n '"<<INIT N>>"' /tmp/instr-init.js   # the statement right AFTER it is the one that threw
//
// NOTE markers are BAKED string literals (no runtime number/string concat) — at bundle scale Porffor
// miscompiles `"x" + number` concatenation into garbage, so never build a marker at runtime here.
import { readFileSync, writeFileSync } from 'node:fs';
import { transformSync } from '@babel/core';

let counter = 0;
const plugin = ({ types: t }) => ({
  name: 'instrument-init',
  visitor: {
    Program(path) {
      const out = [];
      for (const stmt of path.node.body) {
        const idx = counter++;
        // can't place statements before imports/exports; leave those unmarked
        if (/^(Import|Export)/.test(stmt.type)) { out.push(stmt); continue; }
        out.push(t.expressionStatement(t.callExpression(
          t.memberExpression(t.identifier('console'), t.identifier('log')),
          [t.stringLiteral(`<<INIT ${idx}>>`)])));
        out.push(stmt);
      }
      path.node.body = out;
    },
  },
});

const [, , inFile, outFile] = process.argv;
if (!inFile || !outFile) { console.error('usage: node instrument-init.mjs <bundle.js> <out.js>'); process.exit(2); }
const out = transformSync(readFileSync(inFile, 'utf8'),
  { configFile: false, babelrc: false, compact: false, plugins: [plugin], sourceType: 'module' });
writeFileSync(outFile, out.code);
console.error(`[instrument-init] inserted ${counter} top-level markers -> ${outFile}`);
