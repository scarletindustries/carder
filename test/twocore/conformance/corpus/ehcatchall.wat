;; ehcatchall — catch_all + non-matching-catch propagation backstop (capstone P7-10, proof 1).
;; catchall(x): throw $a(x). An inner `try_table (catch $b …)` does NOT match $a, so the exception
;; PROPAGATES to the outer `try_table (catch_all …)`, which catches it → 42. Proves catch-clause
;; ordering, the no-match ⇒ propagate rule (spec §4.4.9), and catch_all-catches-a-wasm-exn.
(module
  (tag $a (param i32))
  (tag $b)
  (func (export "catchall") (param i32) (result i32)
    (block $done (result i32)
      (block $ca
        (try_table (catch_all $ca)
          (block $bt
            (try_table (catch $b $bt)
              (throw $a (local.get 0)))
            (br $done (i32.const 1)))))
      (br $done (i32.const 42)))))
