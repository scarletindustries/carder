;; Acceptance (constant-space) — a memory.store EVERY iteration for ~100k iterations,
;; used to prove the `cell` state strategy preserves the Phase-1 tail-loop / constant-space
;; property for the ACTUAL memory path (not inferred from rt_meter). `store_loop(n)` writes
;; address 0 n times then returns the final loaded value; run at n=100000 it must complete
;; without unbounded process growth (the loop back-edge stays in tail position; the pdict
;; cell is a mutable slot holding an immutable page-map, so no state is loop-carried).
(module
  (memory 1)
  (func (export "store_loop") (param $n i32) (result i32)
    (local $i i32)
    (block $exit
      (loop $cont
        (br_if $exit (i32.ge_u (local.get $i) (local.get $n)))
        (i32.store (i32.const 0) (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cont)))
    (i32.load (i32.const 0))))
