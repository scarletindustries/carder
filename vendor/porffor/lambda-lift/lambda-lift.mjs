// lambda-lift.mjs — work around Porffor's lack of closures over enclosing-function locals
// (FINDINGS §8b) by GLOBALIZING captured variables: Porffor DOES support closures over module-level
// globals, so for each function F we promote every param/local that a nested function reads or writes
// into a fresh module global, and reroute F's own references to it too. A nested closure then reads a
// module global (works) instead of an enclosing local (broken).
//
// Recursion/reentrancy safety: F saves the previous value of each globalized slot on entry and restores
// it at every exit (plain assignment — Porffor's try/finally + closure is broken, so no try/finally).
// This is correct for NON-ESCAPING closures (run synchronously within F's dynamic extent — array-method
// callbacks, immediate helpers). Closures that ESCAPE F (stored and called after F returns) are NOT
// handled and are logged. Mutations of captured OBJECTS (`.push`, property set) work (the pointer is
// shared); reassigning a captured primitive works within F's extent via the global.
//
// Kept deliberately SEPARATE from the main build (its own dir) so it is easy to drop or wire into
// build.sh later. Usage:  node lambda-lift/lambda-lift.mjs <in.js> <out.js>
//
// This is an experiment (FINDINGS §8b): a broad transform over the whole compiler, verified end-to-end
// by whether the self-hosted `[run]` prints probe_len with correct output.

import { readFileSync, writeFileSync } from 'node:fs';
import { transformSync } from '@babel/core';

let uid = 0;
let slotNum = 0;
const globalNames = [];
let stats = { functions: 0, globalized: 0, escaping: 0 };

const plugin = ({ types: t }) => {
  // Walk up from refPath; return the nearest enclosing Function, or null at Program.
  const enclosingFunction = (refPath) => {
    let p = refPath.parentPath;
    while (p) {
      if (p.isFunction()) return p;
      p = p.parentPath;
    }
    return null;
  };
  // Is refPath inside a function nested within fnPath (i.e. a real capture)?
  const isCapturedIn = (refPath, fnPath) => {
    let p = refPath.parentPath;
    while (p && p.node !== fnPath.node) {
      if (p.isFunction()) return true;
      p = p.parentPath;
    }
    return false;
  };

  // Build the restore statements (g = saved) for a set of {g, save} pairs.
  const restoreStmts = (slots) =>
    slots.map(s => t.expressionStatement(t.assignmentExpression('=', t.identifier(s.g), t.identifier(s.save))));

  return {
    name: 'lambda-lift-globalize',
    visitor: {
      Function(fnPath) {
        if (fnPath.node.__ll) return;
        fnPath.node.__ll = true;
        stats.functions++;

        const scope = fnPath.scope;
        const slots = []; // { name, g, save, isParam }

        for (const name of Object.keys(scope.bindings)) {
          const binding = scope.bindings[name];
          // Handle simple PARAMS and function-scope local VARS. Skip complex bindings (destructuring,
          // rest) — their binding.identifier isn't a plain seedable name. let/const captures are handled
          // too (seeded from their declaration like a var).
          if (!['param', 'var', 'let', 'const'].includes(binding.kind)) continue;
          if (!binding.identifier || binding.identifier.type !== 'Identifier') continue;

          const capturedRefs = binding.referencePaths.filter(rp => isCapturedIn(rp, fnPath));
          const capturedViols = binding.constantViolations.filter(vp => isCapturedIn(vp, fnPath));
          if (capturedRefs.length === 0 && capturedViols.length === 0) continue;

          const isParam = binding.kind === 'param';
          // v1: PARAMS ONLY. Local-var globalization is unsound in general (hoisting `g = init` before
          // the declaration can move `init` ahead of variables it depends on; loop/block scoping). Set
          // LL_LOCALS=1 to also attempt simple locals (experimental).
          const declPath = isParam ? null : binding.path;
          if (!isParam) {
            if (!process.env.LL_LOCALS) continue;
            if (!(declPath && declPath.isVariableDeclarator && declPath.isVariableDeclarator())) continue;
          }

          // Globalization with save/restore is only SOUND for closures that run SYNCHRONOUSLY within F's
          // dynamic extent. Rather than try to prove a closure escapes (undecidable — a call arg might be
          // stored, e.g. arr.push(cb) / addEventListener / Object.defineProperty), we WHITELIST: a
          // capturing closure is safe ONLY if it is a direct argument to a known synchronous
          // array/iteration method (reduce/map/filter/…). Every other capturing closure — returned,
          // assigned, stored in an object/array literal (property descriptors, handler maps), or passed
          // to an unknown callee — is treated as escaping and SKIPPED (it was already broken under
          // Porffor, so skipping loses nothing). Correct-by-construction over reach.
          const SYNC = new Set(['reduce','reduceRight','map','filter','forEach','find','findIndex',
            'findLast','findLastIndex','some','every','sort','flatMap','flat','keys','values','entries']);
          const runsSynchronously = (fn) => {
            const par = fn.parentPath;
            if (!par || !par.isCallExpression() || !par.node.arguments.includes(fn.node)) return false;
            const callee = par.node.callee;
            return callee.type === 'MemberExpression' && callee.property.type === 'Identifier' &&
              SYNC.has(callee.property.name);
          };
          const capturingFns = new Set();
          for (const rp of [...capturedRefs, ...capturedViols]) {
            const fn = enclosingFunction(rp);
            if (fn && fn.node !== fnPath.node) capturingFns.add(fn);
          }
          if (![...capturingFns].every(runsSynchronously)) { stats.escaping++; continue; }

          // SKIP captures inside a loop: a closure created per-iteration must capture its own binding,
          // but a single global would share one slot across iterations (classic loop-closure bug).
          let inLoop = false;
          for (const rp of capturedRefs) {
            let p = rp.parentPath;
            while (p && p.node !== fnPath.node) {
              if (p.isLoop()) { inLoop = true; break; }
              p = p.parentPath;
            }
            if (inLoop) break;
          }
          if (inLoop) { stats.inLoop = (stats.inLoop || 0) + 1; continue; }

          // debug: LL_MAX limits how many slots are globalized (binary-search a bad slot)
          if (process.env.LL_MAX != null && slotNum >= +process.env.LL_MAX) continue;
          if (process.env.LL_MIN != null && slotNum < +process.env.LL_MIN) { slotNum++; continue; }
          slotNum++;

          const g = `__ll$${uid++}`;
          const save = `${g}$s`;
          globalNames.push(g);
          slots.push({ name, g, save, isParam, binding, declPath });
          if (process.env.LL_DEBUG) {
            const fnName = fnPath.node.id?.name || fnPath.parent?.id?.name ||
              (fnPath.parentPath?.isVariableDeclarator() && fnPath.parent.id?.name) || '<anon>';
            const loc = fnPath.node.loc ? `L${fnPath.node.loc.start.line}` : '';
            console.error(`slot ${slotNum - 1}: ${isParam ? 'param' : 'local'} '${name}' in ${fnName} ${loc}`);
          }
        }

        if (slots.length === 0) return;
        stats.globalized += slots.length;

        // Ensure a block body so we can prepend save/seed and handle returns.
        if (!t.isBlockStatement(fnPath.node.body)) {
          fnPath.get('body').replaceWith(t.blockStatement([t.returnStatement(fnPath.node.body)]));
        }
        const body = fnPath.get('body');

        const saves = []; // var g$s = g;   (run first, at entry)
        const seeds = []; // g = <param>;   (params only; locals seed at their declaration)
        for (const slot of slots) {
          const { name, g, save, isParam, binding, declPath } = slot;
          saves.push(t.variableDeclaration('var', [t.variableDeclarator(t.identifier(save), t.identifier(g))]));
          // seed params from their (unchanged) name; the param keeps its name and is only read here.
          if (isParam) seeds.push(t.expressionStatement(t.assignmentExpression('=', t.identifier(g), t.identifier(name))));

          // Is a reference inside F's OWN parameter list (a param default)? Those evaluate BEFORE the
          // body seed `g = name`, so they must keep reading the real param, not the not-yet-seeded global.
          const inParams = (rp) => {
            let p = rp;
            while (p && p.node !== fnPath.node) {
              if (fnPath.node.params.includes(p.node)) return true;
              p = p.parentPath;
            }
            return false;
          };
          // reroute reads to the global (guard against paths made stale by earlier mutations)
          for (const rp of binding.referencePaths) {
            if (!rp.node || rp.removed || !rp.container) continue;
            if (inParams(rp)) continue; // param-default ref — leave as the real param
            try { rp.replaceWith(t.identifier(g)); } catch { /* stale */ }
          }
          // reroute writes (assignments / updates)
          for (const vp of binding.constantViolations) {
            if (!vp.node || vp.removed || !vp.container) continue;
            try {
              if (vp.isAssignmentExpression() && t.isIdentifier(vp.node.left, { name })) {
                vp.get('left').replaceWith(t.identifier(g));
              } else if (vp.isUpdateExpression() && t.isIdentifier(vp.node.argument, { name })) {
                vp.get('argument').replaceWith(t.identifier(g));
              }
            } catch { /* stale */ }
          }
          // for a local, convert its declarator `name = init` -> `g = init` (seed at declaration site)
          if (!isParam && declPath && !declPath.removed && declPath.container) {
            try {
              const init = declPath.node.init;
              declPath.parentPath.insertBefore(
                t.expressionStatement(t.assignmentExpression('=', t.identifier(g), init || t.identifier('undefined'))),
              );
              declPath.remove();
            } catch { /* stale */ }
          }
        }

        body.node.body.unshift(...saves, ...seeds);

        // Restore before every return in F (not in nested functions), and at the fall-through end.
        const restores = restoreStmts(slots);
        fnPath.traverse({
          Function(inner) { inner.skip(); }, // don't touch nested returns
          ReturnStatement(rp) {
            if (rp.node.__ll_ret) return; // don't re-process a return we just generated
            const arg = rp.node.argument;
            const ret = t.returnStatement(arg ? null : undefined);
            ret.__ll_ret = true;
            if (arg) {
              const tmp = `__ll$r${uid++}`;
              ret.argument = t.identifier(tmp);
              rp.replaceWithMultiple([
                t.variableDeclaration('var', [t.variableDeclarator(t.identifier(tmp), arg)]),
                ...restores.map(r => t.cloneNode(r)),
                ret,
              ]);
            } else {
              rp.replaceWithMultiple([...restores.map(r => t.cloneNode(r)), ret]);
            }
          },
        });
        // fall-through restore
        body.node.body.push(...restores.map(r => t.cloneNode(r)));
      },
    },
  };
};

const [, , inFile, outFile] = process.argv;
if (!inFile || !outFile) {
  console.error('usage: node lambda-lift.mjs <in.js> <out.js>');
  process.exit(2);
}
const src = readFileSync(inFile, 'utf8');
const out = transformSync(src, {
  configFile: false, babelrc: false, compact: false, plugins: [plugin], sourceType: 'module',
});
const decls = globalNames.length ? `var ${globalNames.join(', ')};\n` : '';
writeFileSync(outFile, decls + out.code);
console.error(
  `[lambda-lift] functions=${stats.functions} globalized-slots=${stats.globalized} ` +
  `(${globalNames.length} globals) SKIPPED: escaping=${stats.escaping} in-loop=${stats.inLoop || 0}` +
  `${process.env.LL_LOCALS ? ' (+locals)' : ' (params-only; set LL_LOCALS=1 for locals)'} -> ${outFile}`,
);
