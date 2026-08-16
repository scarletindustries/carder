;; An IN-SCOPE .wast script exercising the wat_fixture adapter end-to-end (P5-11 §E):
;; a module + assert_return + assert_trap + a (module quote) malformed rejection + register/invoke.
(module $m
  (memory 1)
  (func (export "add") (param i32 i32) (result i32) (local.get 0) (local.get 1) (i32.add))
  (func (export "divs") (param i32 i32) (result i32) (local.get 0) (local.get 1) (i32.div_s))
  (func (export "store_load") (param i32 i32) (result i32)
    (local.get 0) (local.get 1) (i32.store)
    (local.get 0) (i32.load)))
(assert_return (invoke "add" (i32.const 7) (i32.const 35)) (i32.const 42))
(assert_return (invoke "add" (i32.const 2147483647) (i32.const 1)) (i32.const 0x80000000))
(assert_trap (invoke "divs" (i32.const 1) (i32.const 0)) "integer divide by zero")
(assert_return (invoke "store_load" (i32.const 0) (i32.const 123456)) (i32.const 123456))
;; a malformed quoted module MUST be rejected at parse (a leading-underscore float literal).
(assert_malformed (module quote "(global f32 (f32.const _100))") "unknown operator")
;; register the module and invoke it by its link name (cross-module invoke via the registry).
(register "M" $m)
(assert_return (invoke $m "add" (i32.const 40) (i32.const 2)) (i32.const 42))
