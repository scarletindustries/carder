;; reftab — reference & table instructions (ref.func/ref.null/ref.is_null,
;; table.get/set/size/grow/fill, call_indirect through a null slot → trap).
;; All results are i32 (null-ness / call results), so the .expected format applies.
;; Spec: https://webassembly.github.io/spec/core/exec/instructions.html#table-instructions
(module
  (type $ii (func (param i32) (result i32)))
  (table $t 3 funcref)
  (func $inc (param i32) (result i32) (local.get 0) (i32.const 1) (i32.add))
  (elem (i32.const 0) $inc)  ;; slot 0 = inc; slots 1,2 null
  (func (export "isnull") (param i32) (result i32)
    (local.get 0) (table.get $t) (ref.is_null))
  (func (export "call0") (param i32) (result i32)
    (local.get 0) (i32.const 0) (call_indirect $t (type $ii)))
  (func (export "callnull") (param i32) (result i32)
    (local.get 0) (i32.const 2) (call_indirect $t (type $ii)))
  (func (export "size") (result i32) (table.size $t))
  (func (export "setcall") (param i32) (result i32)
    (i32.const 1) (ref.func $inc) (table.set $t)
    (local.get 0) (i32.const 1) (call_indirect $t (type $ii)))
  (func (export "grow2") (result i32) (ref.null func) (i32.const 2) (table.grow $t))
  (func (export "fill1") (result i32)
    (i32.const 1) (ref.func $inc) (i32.const 1) (table.fill $t)
    (i32.const 1) (table.get $t) (ref.is_null)))
