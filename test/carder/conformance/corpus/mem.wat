;; Acceptance #1 — linear memory round-trip + out-of-bounds traps.
;; Proves: i32.store then i32.load round-trips; an OOB load AND a partial multi-byte
;; OOB store both trap ("out of bounds memory access"); the failed store mutates
;; ZERO bytes (load8 of an in-bounds byte the store would have touched reads 0).
;; Bounds semantics: ea = addr + offset (unsigned, no wrap); trap iff ea+N > 65536.
(module
  (memory 1)                                   ;; one 64 KiB page → valid i32.store at 0..65532
  (func (export "roundtrip") (param $a i32) (param $v i32) (result i32)
    (i32.store (local.get $a) (local.get $v))
    (i32.load (local.get $a)))
  (func (export "load") (param $a i32) (result i32)
    (i32.load (local.get $a)))                 ;; 4-byte load; OOB → trap
  (func (export "store") (param $a i32) (param $v i32)
    (i32.store (local.get $a) (local.get $v))) ;; 4-byte store; OOB → trap, no write
  (func (export "load8") (param $a i32) (result i32)
    (i32.load8_u (local.get $a))))             ;; 1-byte load to verify zero mutation
