;; Embedder host-bridge proving fixture.
;; Imports a host function `dance.poke(ptr,len)`, writes "ABC" into linear memory,
;; then calls the host with (ptr=0, len=3). The host closure reads those 3 bytes
;; back out of the guest's memory — proving embedder-injected host functions can
;; marshal over the guest's linear memory. `run` returns the byte count (3).
(module
  (import "dance" "poke" (func $poke (param i32 i32)))
  (memory (export "mem") 1)
  (func (export "run") (result i32)
    (i32.store8 (i32.const 0) (i32.const 65))  ;; 'A'
    (i32.store8 (i32.const 1) (i32.const 66))  ;; 'B'
    (i32.store8 (i32.const 2) (i32.const 67))  ;; 'C'
    (call $poke (i32.const 0) (i32.const 3))
    (i32.const 3)))
