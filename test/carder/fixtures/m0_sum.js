function sum(n) {
  let s = 0;
  for (let i = 0; i < n; i++) s += i;
  return s;
}
const t0 = Date.now();
let r;
for (let k = 0; k < 100; k++) r = sum(1000000);
const t1 = Date.now();
console.log("sum(1M)x100 = " + r + " in " + (t1 - t0) + " ms → " + (t1 - t0) * 10 + " µs/call");
