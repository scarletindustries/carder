;; newsurface_check — SELF-CONTAINED (one-call) bulk-memory + multi-memory functions for the
;; Tier-B wasmtime differential (each fully sets up + observes in a single invoke, since wasmtime
;; runs one function per fresh instance). i32-observable.
(module
  (memory $a 1)
  (memory $b 1)
  (data $d "abcd")  ;; [97,98,99,100]
  ;; fill mem $a [0,4)='X'(88), then memory.init $d dst=1 src=1 count=2 → mem[1..3)=[98,99]; return mem[1]=98.
  (func (export "bulk_check") (result i32)
    (i32.const 0) (i32.const 88) (i32.const 4) (memory.fill $a)
    (i32.const 1) (i32.const 1) (i32.const 2) (memory.init $a $d)
    (i32.const 1) (i32.load8_u $a))
  ;; overlap memmove: fill [0,4)=1..4 by stores, copy [0,4)->[2,6), return byte at 3 (must be the OLD [1]).
  (func (export "overlap_check") (result i32)
    (i32.const 0) (i32.const 0x04030201) (i32.store $a)
    (i32.const 2) (i32.const 0) (i32.const 4) (memory.copy $a $a)
    (i32.const 3) (i32.load8_u $a))
  ;; multi-memory: store to $b, copy $b->$a, load from $a (independent regions + cross-mem copy).
  (func (export "multimem_check") (result i32)
    (i32.const 0) (i32.const 0x11223344) (i32.store $b)
    (i32.const 0) (i32.const 0) (i32.const 4) (memory.copy $a $b)
    (i32.const 0) (i32.load $a)))
