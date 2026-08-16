;; Phase-3 unit 11 proof 4 — a runaway TAIL loop: an unbounded back-edge charged
;; every iteration. Under a small `profiles.safe_metered(budget)` it traps
;; FuelExhausted deterministically, in constant space (tail-`apply` back-edge).
(module
  (func (export "spin")
    (loop $l (br $l))))
