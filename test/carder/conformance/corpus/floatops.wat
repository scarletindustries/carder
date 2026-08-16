;; One f32 + one f64 program exercised through the FULL WASM pipeline. The Phase-1
;; WASM frontend decodes float CONSTANTS and the trunc_sat conversions (not yet float
;; arithmetic), so this covers the float-as-raw-bits value path (D5) and rt_num's
;; float->int conversions end-to-end. (Float ARITHMETIC — unit 06's FAdd/FMul — is
;; covered end-to-end from hand-built IR in corpus_test, since the decoder has no
;; f32.add yet; that frontend gap is a documented Phase-2 item.)
(module
  (func (export "f32const") (result f32) (f32.const 1.5))
  (func (export "f64const") (result f64) (f64.const 2.5))
  (func (export "f32toi") (param f32) (result i32)
    (i32.trunc_sat_f32_s (local.get 0)))
  (func (export "f64toi") (param f64) (result i32)
    (i32.trunc_sat_f64_s (local.get 0))))
