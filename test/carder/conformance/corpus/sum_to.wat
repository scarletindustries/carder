;; sum_to(n) = 1+2+...+n via a loop/break/continue — lowers to a constant-space
;; tail-recursive BEAM loop. Closed form n*(n+1)/2 (cross-checked via wasmtime).
(module
  (func (export "sum_to") (param $n i32) (result i32)
    (local $i i32) (local $acc i32)
    (local.set $i (i32.const 1))
    (local.set $acc (i32.const 0))
    (block $brk
      (loop $cont
        (br_if $brk (i32.gt_s (local.get $i) (local.get $n)))
        (local.set $acc (i32.add (local.get $acc) (local.get $i)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cont)))
    (local.get $acc)))
