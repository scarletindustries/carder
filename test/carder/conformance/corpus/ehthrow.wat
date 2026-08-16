;; ehthrow — the LEGACY `try`/`catch` backstop (the encoding PORFFOR actually emits, capstone P7-10).
;; `run(x)`: a legacy `try { if x≠0 throw $e(x) ; else 7 } catch $e { payload+1 }`. Proves the legacy
;; inline-handler path (the JS-on-the-BEAM headline path) end to end with a scalar result.
(module
  (tag $e (param i32))
  (func (export "run") (param i32) (result i32)
    (try (result i32)
      (do
        (if (i32.ne (local.get 0) (i32.const 0))
          (then (throw $e (local.get 0))))
        (i32.const 7))
      (catch $e
        (i32.add (i32.const 1))))))
