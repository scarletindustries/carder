;; Acceptance #6 — the module used by the cross-instance ISOLATION test. Two instances of
;; THIS module (two owned processes) must never observe each other's memory or globals.
;; Carries both a mutable global and linear memory so isolation is proven for both.
(module
  (memory 1)
  (global $g (mut i32) (i32.const 0))
  (func (export "set_global") (param i32) (global.set $g (local.get 0)))
  (func (export "get_global") (result i32) (global.get $g))
  (func (export "store") (param $a i32) (param $v i32) (i32.store (local.get $a) (local.get $v)))
  (func (export "load") (param $a i32) (result i32) (i32.load (local.get $a))))
