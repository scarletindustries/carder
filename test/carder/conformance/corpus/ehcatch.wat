;; ehcatch — the MODERN `try_table` catch→ENCLOSING-label transfer backstop (capstone P7-10, proof 1).
;; This is the exact IR shape (a Block broken to ONLY from inside a Try catch handler) that the EH
;; `.wast` run surfaced as an optimizer block-elimination bug. `catch(x)`: a `try_table` whose body
;; throws `$e(x*10)` when x≠0, with `(catch $e $out)` transferring the payload to the enclosing
;; block `$out`; when x==0 the body falls through with a sentinel 999. Scalar-observable (Deviation
;; #2) so it rides the byte-identical numeric Outcome across safe/unsafe/portable.
(module
  (tag $e (param i32))
  (func (export "catch") (param i32) (result i32)
    (block $out (result i32)
      (try_table (result i32) (catch $e $out)
        (if (i32.ne (local.get 0) (i32.const 0))
          (then (throw $e (i32.mul (local.get 0) (i32.const 10)))))
        (i32.const 999)))))
