;; Integer edges that must hold THROUGH codegen: signed/unsigned divide pair on a
;; value that differs, the div_s(INT_MIN,-1) overflow trap, the div_u(_,0) trap, and
;; a shift with count >= width (spec masks the count mod 32).
(module
  (func (export "divs") (param i32 i32) (result i32)
    (i32.div_s (local.get 0) (local.get 1)))
  (func (export "divu") (param i32 i32) (result i32)
    (i32.div_u (local.get 0) (local.get 1)))
  (func (export "rems") (param i32 i32) (result i32)
    (i32.rem_s (local.get 0) (local.get 1)))
  (func (export "shl") (param i32 i32) (result i32)
    (i32.shl (local.get 0) (local.get 1))))
