;; Phase-13 acceptance — constant-stack tail calls (return_call / return_call_indirect).
;; Per the WASM tail-call proposal, return_call{,_indirect} are stack-polymorphic like `return`
;; and require the callee's result type to equal the current function's result type; on the BEAM
;; they lower to genuine tail calls, so deep self/mutual recursion runs in CONSTANT stack space.
;; Values cross-checked with the 2core pipeline (Tier-A) at authoring time — NOT change-detectors.
(module
  (type $unary  (func (param i32) (result i32)))
  (type $binary (func (param i32 i32) (result i32)))
  (table 2 funcref)                 ;; slot 0 = $ind_step (filled by elem); slot 1 = null
  (elem (i32.const 0) $ind_step)

  ;; --- direct self-loop: count_down(n) tail-calls itself until 0 ---
  (func $count_down (export "count_down") (param $n i32) (result i32)
    (if (result i32) (i32.eqz (local.get $n))
      (then (i32.const 0))
      (else (return_call $count_down (i32.sub (local.get $n) (i32.const 1))))))

  ;; --- mutual recursion: is_even / is_odd via return_call ---
  (func $is_even (export "is_even") (param $n i32) (result i32)
    (if (result i32) (i32.eqz (local.get $n))
      (then (i32.const 1))
      (else (return_call $is_odd (i32.sub (local.get $n) (i32.const 1))))))
  (func $is_odd (export "is_odd") (param $n i32) (result i32)
    (if (result i32) (i32.eqz (local.get $n))
      (then (i32.const 0))
      (else (return_call $is_even (i32.sub (local.get $n) (i32.const 1))))))

  ;; --- indirect self-loop through table slot 0 ---
  (func $ind_step (param $n i32) (result i32)
    (if (result i32) (i32.eqz (local.get $n))
      (then (i32.const 0))
      (else (return_call_indirect (type $unary)
              (i32.sub (local.get $n) (i32.const 1)) (i32.const 0)))))
  (func (export "ind_count_down") (param $n i32) (result i32)
    (return_call_indirect (type $unary) (local.get $n) (i32.const 0)))

  ;; --- the three ordered indirect fail-closed guards (same traps + order as call_indirect) ---
  (func (export "ind_oob")  (param $n i32) (result i32)          ;; idx 5 >= size 2 -> undefined element
    (return_call_indirect (type $unary) (local.get $n) (i32.const 5)))
  (func (export "ind_null") (param $n i32) (result i32)          ;; slot 1 present-but-null -> uninit
    (return_call_indirect (type $unary) (local.get $n) (i32.const 1)))
  (func (export "ind_type") (param $a i32) (param $b i32) (result i32)  ;; slot 0 is $unary, called $binary
    (return_call_indirect (type $binary) (local.get $a) (local.get $b) (i32.const 0))))
