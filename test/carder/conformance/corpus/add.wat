;; add(i32,i32) — direct numeric op, params, export, end-to-end plumbing.
;; mul exercises i32 two's-complement WRAP through codegen (i32.mul is mod 2^32).
(module
  (func (export "add") (param i32 i32) (result i32)
    (i32.add (local.get 0) (local.get 1)))
  (func (export "mul") (param i32 i32) (result i32)
    (i32.mul (local.get 0) (local.get 1))))
