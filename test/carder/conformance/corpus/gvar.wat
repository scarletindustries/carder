;; Acceptance #3 — a mutable global round-trips through global.set / global.get.
;; (An immutable global rejecting global.set is enforced at validation by unit 08 and
;; covered by the spec global.wast assert_invalid set.) State persists across invokes
;; because the instance owns one process (one-instance-one-process).
(module
  (global $g (mut i32) (i32.const 7))
  (func (export "get") (result i32) (global.get $g))
  (func (export "set") (param i32) (global.set $g (local.get 0))))
