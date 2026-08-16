function mk() { let c = 0; return function () { c++; return c } }
let f = mk()
f(); f()
console.log(f())
