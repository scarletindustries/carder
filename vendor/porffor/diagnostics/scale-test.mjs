// scale-test.mjs — generate a program with N functions to find function-COUNT thresholds where
// Porffor self-compile bugs kick in (this is a FAST loop — small program, ~1 s compile — unlike the
// 10 s bundle build). Used to localize the "function .prototype is undefined past ~7-8k funcs" wall
// (FINDINGS §7): 6000 funcs -> prototype works; 8000 -> `TypeError: Cannot set property of undefined`.
//
// Usage (run from vendor/porffor):
//   node diagnostics/scale-test.mjs 8000 > /tmp/scale.js
//   npx porffor run --module /tmp/scale.js
//   # prints  proto_object=true/false  and  method=42  when prototypes still work.
//
// The dummy functions are pushed into a sink array so they are all "indirect" (kept, not tree-shaken).
const N = parseInt(process.argv[2] || '8000', 10);
let s = 'var _sink = [];\n';
for (let i = 0; i < N; i++) s += `function f${i}(a){ return a+${i}; }\n_sink.push(f${i});\n`;
s += 'var P = function P2(a){ this.a = a; };\n';
s += 'P.prototype.m = function(){ return this.a * 2; };\n';
s += 'console.log("proto_object=" + (typeof P.prototype === "object"));\n';
s += 'console.log("method=" + (new P(21)).m());\n';
process.stdout.write(s);
