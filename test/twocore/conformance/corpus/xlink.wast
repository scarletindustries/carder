;; xlink — the CROSS-MODULE function-linking backstop (capstone P6-11, proof 3, I5). Module $a
;; exports two functions; (register "a" $a) publishes them as cross-module capabilities; module
;; $b imports and CALLS them across instances via the linker-built closure (D3a — a handed-in
;; capability, never an ambient apply of an attacker-named module:atom). An unsatisfied import
;; fails closed at link time (assert_unlinkable). Values spec-obvious (arithmetic).
(module $a
  (func (export "add10") (param i32) (result i32)
    (i32.add (local.get 0) (i32.const 10)))
  (func (export "mul2") (param i32) (result i32)
    (i32.mul (local.get 0) (i32.const 2))))
(register "a" $a)
(module $b
  (import "a" "add10" (func $add10 (param i32) (result i32)))
  (import "a" "mul2" (func $mul2 (param i32) (result i32)))
  ;; chain(x) = mul2(add10(x)) — a cross-instance call composed with a second cross-instance call.
  (func (export "chain") (param i32) (result i32)
    (call $mul2 (call $add10 (local.get 0))))
  ;; direct(x) = add10(x) — the single cross-module dispatch, isolated.
  (func (export "direct") (param i32) (result i32)
    (call $add10 (local.get 0))))
(assert_return (invoke $b "chain" (i32.const 5)) (i32.const 30))
(assert_return (invoke $b "chain" (i32.const 0)) (i32.const 20))
(assert_return (invoke $b "direct" (i32.const 100)) (i32.const 110))
;; fail-closed: importing a function module $a does not export → unlinkable at link time.
(assert_unlinkable
  (module (import "a" "nonexistent" (func (param i32) (result i32))))
  "unknown import")
