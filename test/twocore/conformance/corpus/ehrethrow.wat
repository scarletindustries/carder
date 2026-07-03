;; ehrethrow — exnref capture + throw_ref re-raise backstop (capstone P7-10, proof 1).
;; rethrow(x): throw $e(x). An inner `try_table (catch_all_ref …)` captures the exception as an
;; `exnref` (delivered to block $rr); `throw_ref` re-raises that captured handle; the OUTER
;; `try_table (catch $e …)` catches the re-raised exception and binds its payload → payload+1000.
;; Proves the modern exnref/throw_ref re-raise surface (spec `throw_ref` 0x0A; the `exnref` heap
;; type) — Porffor-inert, spec-conformance-only (T9).
(module
  (tag $e (param i32))
  (func (export "rethrow") (param i32) (result i32)
    (i32.add
      (block $out (result i32)
        (try_table (catch $e $out)
          (throw_ref
            (block $rr (result exnref)
              (try_table (catch_all_ref $rr)
                (throw $e (local.get 0)))
              (unreachable))))
        (unreachable))
      (i32.const 1000))))
