;; simdxform — the SIMD FLOAT-lane + lanewise-misc backstop kernel (capstone P6-11, proof 1).
;; Exercises: f32x4.splat/mul/add/sqrt/min (IEEE-754 single-rounding, -0.0/NaN corners per I3),
;; i8x16.shuffle (16 immediates), v128.bitselect, i32x4.eq (→ a lane mask), and extract_lane.
;; Each export returns a SCALAR (Deviation #2). Values spec-sourced (cross-checked vs wasmtime).
(module
  ;; f32x4 fused multiply-add: splat(x) * [1.5,2.5,3.5,4.5] + [10,10,10,10]; read lane 2.
  (func (export "fma") (param f32) (result f32)
    (f32x4.extract_lane 2
      (f32x4.add
        (f32x4.mul (f32x4.splat (local.get 0)) (v128.const f32x4 1.5 2.5 3.5 4.5))
        (v128.const f32x4 10 10 10 10))))

  ;; f32x4 sqrt then min with 3.0 (NaN/ordering corner); read lane 0.
  (func (export "sqrtmin") (param f32) (result f32)
    (f32x4.extract_lane 0
      (f32x4.min
        (f32x4.sqrt (f32x4.splat (local.get 0)))
        (v128.const f32x4 3 3 3 3))))

  ;; byte shuffle: bytes 4..7 of vector a become lane 0 — picks a's lane 1 (=20) into lane 0.
  (func (export "shuf") (result i32)
    (i32x4.extract_lane 0
      (i8x16.shuffle 4 5 6 7  0 1 2 3  12 13 14 15  8 9 10 11
        (v128.const i32x4 10 20 30 40)
        (v128.const i32x4 50 60 70 80))))

  ;; bitselect via an i32x4.eq mask: lane 0 picks from a when (x==7), else from b.
  (func (export "bsel") (param i32) (result i32)
    (i32x4.extract_lane 0
      (v128.bitselect
        (v128.const i32x4 111 222 333 444)
        (v128.const i32x4 999 888 777 666)
        (i32x4.eq (i32x4.splat (local.get 0)) (v128.const i32x4 7 0 0 0))))))
