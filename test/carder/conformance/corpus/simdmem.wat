;; simdmem — the SIMD MEMORY backstop kernel (capstone P6-11, proof 1). v128.load/store +
;; load32_splat + store32_lane/load32_lane through the bounds-checked rt_mem seam, plus an
;; out-of-bounds v128.load → trap "out of bounds memory access" (no host escape, I6). Little-
;; endian lane layout is exact. Scalar-observable (Deviation #2); values cross-checked vs wasmtime.
(module
  (memory 1)
  ;; store an i32x4 splat vector, load it back, read lane 3 — a v128.store/load round-trip.
  (func (export "st_ld") (param i32) (result i32)
    (v128.store (i32.const 0) (i32x4.splat (local.get 0)))
    (i32x4.extract_lane 3 (v128.load (i32.const 0))))

  ;; write a scalar, splat-load it into all 4 lanes, read lane 1 — v128.load32_splat.
  (func (export "splat") (param i32) (result i32)
    (i32.store (i32.const 16) (local.get 0))
    (i32x4.extract_lane 1 (v128.load32_splat (i32.const 16))))

  ;; store lane 2 of splat(x) (=x) via v128.store32_lane, read it back as an i32.
  (func (export "lane") (param i32) (result i32)
    (v128.store32_lane 2 (i32.const 32) (i32x4.splat (local.get 0)))
    (i32.load (i32.const 32)))

  ;; a v128.load straddling the 1-page end (65530+16 > 65536) → out-of-bounds trap.
  (func (export "oob") (result i32)
    (i32x4.extract_lane 0 (v128.load (i32.const 65530)))))
