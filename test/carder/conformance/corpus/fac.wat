;; fac — if + direct self-call + recursion. (Spec also bakes fac in the vendored
;; fac.wast; this authored copy keeps the corpus self-contained.)
(module
  (func $fac (export "fac") (param $n i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $n) (i32.const 2))
      (then (i32.const 1))
      (else
        (i32.mul (local.get $n)
                 (call $fac (i32.sub (local.get $n) (i32.const 1))))))))
