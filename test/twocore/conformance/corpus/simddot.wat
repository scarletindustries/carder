;; simddot — the SIMD INTEGER-lane backstop kernel (capstone P6-11, proof 1).
;; A real dot-product kernel + the saturating-add family + lanewise mul/max, each exported
;; with a SCALAR result (an extract_lane reduction) so it rides the byte-identical numeric
;; Outcome across modes/tiers (capstone Deviation #2). Exercises: v128.const, i16x8.splat,
;; i32x4.dot_i16x8_s, i32x4.extract_lane, i16x8.add_sat_s, i16x8.extract_lane_s, i32x4.splat,
;; i32x4.mul, i32x4.max_s. Expected values are spec-sourced (cross-checked vs wasmtime 46.0.1).
(module
  ;; dot product of the constant vector [1..8] (i16x8) with splat(scale): the four i32x4.dot
  ;; lanes are [1s+2s, 3s+4s, 5s+6s, 7s+8s] = [3s,7s,11s,15s]; their sum is 36*scale.
  (func (export "dot8") (param i32) (result i32)
    (local $d v128)
    (local.set $d
      (i32x4.dot_i16x8_s
        (v128.const i16x8 1 2 3 4 5 6 7 8)
        (i16x8.splat (local.get 0))))
    (i32.add
      (i32.add (i32x4.extract_lane 0 (local.get $d))
               (i32x4.extract_lane 1 (local.get $d)))
      (i32.add (i32x4.extract_lane 2 (local.get $d))
               (i32x4.extract_lane 3 (local.get $d)))))

  ;; saturating signed add: splat(x) into i16x8 + 30000, clamps at +32767 (two's-complement lane).
  (func (export "addsat") (param i32) (result i32)
    (i16x8.extract_lane_s 0
      (i16x8.add_sat_s
        (i16x8.splat (local.get 0))
        (v128.const i16x8 30000 30000 30000 30000 30000 30000 30000 30000))))

  ;; lanewise mul then signed max with a floor of 100 in lane 2, extract lane 2.
  (func (export "lanes") (param i32) (result i32)
    (i32x4.extract_lane 2
      (i32x4.max_s
        (i32x4.mul (i32x4.splat (local.get 0)) (v128.const i32x4 1 2 3 4))
        (v128.const i32x4 0 0 100 0)))))
