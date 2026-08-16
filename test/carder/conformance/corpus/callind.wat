;; Acceptance #2 — call_indirect with the three ordered, distinct faults.
;; Proves the runtime type-check dispatch (never a data-driven apply): right type runs;
;; an OUT-OF-BOUNDS index traps "undefined element"; a NULL slot traps "uninitialized
;; element"; a TYPE MISMATCH traps "indirect call type mismatch". Check order (spec
;; exec/instructions.html): bounds, then null, then type.
(module
  (type $unary  (func (param i32) (result i32)))
  (type $binary (func (param i32 i32) (result i32)))
  (table 3 funcref)                              ;; slots 0,1 filled by elem; slot 2 = null
  (func $inc (param i32) (result i32) (i32.add (local.get 0) (i32.const 1)))
  (func $dbl (param i32) (result i32) (i32.mul (local.get 0) (i32.const 2)))
  (elem (i32.const 0) $inc $dbl)
  ;; call slot $i with arg $x, expecting the UNARY type
  (func (export "call_unary") (param $i i32) (param $x i32) (result i32)
    (call_indirect (type $unary) (local.get $x) (local.get $i)))
  ;; call slot $i with two args, expecting the BINARY type (slots are unary → mismatch)
  (func (export "call_binary") (param $i i32) (param $x i32) (result i32)
    (call_indirect (type $binary) (local.get $x) (local.get $x) (local.get $i))))
