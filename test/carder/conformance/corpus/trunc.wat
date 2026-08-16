;; Acceptance #5 — trapping i32.trunc_f32_s (spec exec/numerics.html).
;; NaN / ±Inf → "invalid conversion to integer"; out-of-range finite → "integer overflow";
;; in-range → truncate toward zero. f32 args are raw IEEE-754 bit patterns (D5).
(module
  (func (export "trunc_s") (param f32) (result i32) (i32.trunc_f32_s (local.get 0))))
