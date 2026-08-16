;; Phase-3 unit 11 proof 4 — a runaway NON-TAIL recursion: the call result is
;; consumed by i32.add, so a frame must be kept. Charged fn_cost per call, so fuel
;; bounds recursion DEPTH (node memory O(budget), not constant — unit 05 §C.3).
(module
  (func $r (export "recurse") (param $n i32) (result i32)
    (i32.add (i32.const 1) (call $r (i32.const 0)))))
