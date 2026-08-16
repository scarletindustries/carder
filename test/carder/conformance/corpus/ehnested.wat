;; ehnested — nested try_table, innermost-matching-handler unwinding backstop (capstone P7-10).
;; nested(x): throw $b(x). The INNER `try_table (catch $a …)` does NOT match $b, so the exception
;; skips it and propagates to the OUTER `try_table (catch $b …)`, which binds the payload and
;; delivers it to `$bout`; the result is payload+100. Proves nested unwinding to the correct level
;; (spec §4.4.9) — a wrong-level catch would return the wrong value here.
(module
  (tag $a (param i32))
  (tag $b (param i32))
  (func (export "nested") (param i32) (result i32)
    (i32.add
      (block $bout (result i32)
        (try_table (catch $b $bout)
          (block $aout (result i32)
            (try_table (catch $a $aout)
              (throw $b (local.get 0)))
            (unreachable))
          (br $bout (i32.const 999)))
        (unreachable))
      (i32.const 100))))
