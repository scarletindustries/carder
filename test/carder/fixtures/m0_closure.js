function makeAdder(x) {
  return function (y) {
    return x + y;
  };
}
const add5 = makeAdder(5);
const t0 = Date.now();
let r;
for (let k = 0; k < 100; k++) {
  let s = 0;
  for (let i = 0; i < 1000000; i++) s += add5(i);
  r = s;
}
const t1 = Date.now();
console.log("closure(1M)x100 = " + r + " in " + (t1 - t0) + " ms → " + (t1 - t0) * 10 + " µs/call");
