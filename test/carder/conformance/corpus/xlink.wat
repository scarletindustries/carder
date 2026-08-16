;; Phase-14 acceptance — cross-module funcref-in-elem-segment init + call_indirect of an IMPORTED
;; function. Per the WASM spec (element segments; §2.5.6 / §4.5.4 / instantiation): the funcidx space
;; is unified — imports occupy 0..n-1 — so `ref.func x` for an IMPORTED x yields that import's function
;; reference; an active elem writes it into the table at the offset. Per §exec/instructions
;; (call_indirect §4.4.8), a call through such a slot dispatches to the imported function and MUST
;; behave IDENTICALLY to a direct `call` of that import; the three fail-closed guards (bounds → null →
;; exact type) evaluate in that order. Values are spec-obvious (arithmetic); cross-checked with
;; wasmtime 46.0.1 at authoring time (ef0(5)=15, ef1(5)=10).
;;
;; This module is the IMPORTER `$b` (compiled by wat2wasm to `xlink.wasm`, decoded by our decoder AND
;; parsed by our WAT parser). An imported funcref REQUIRES a provider, so the pipeline drives it with
;; a provider module `$a` `(register)`ed under name "a" — supplied by the capstone test
;; (`combos.evaluate_linked`), exactly as `table_copy.wast`'s cross-module plumbing runs:
;;   (module $a
;;     (func (export "ef0") (param i32) (result i32) (i32.add (local.get 0) (i32.const 10)))
;;     (func (export "ef1") (param i32) (result i32) (i32.mul (local.get 0) (i32.const 2))))
;;   (register "a" $a)
;; Single funcref table of size 4: slots 0/1/2 are written by the MIXED active elem below (imported
;; ef0, defined, imported ef1), slot 3 stays null for the uninitialized-element guard.
(module
  (type $unary  (func (param i32) (result i32)))
  (type $binary (func (param i32 i32) (result i32)))
  (import "a" "ef0" (func $ef0 (param i32) (result i32)))   ;; funcidx 0 (imported)
  (import "a" "ef1" (func $ef1 (param i32) (result i32)))   ;; funcidx 1 (imported)
  (func $defined (param i32) (result i32) (i32.sub (local.get 0) (i32.const 1)))  ;; funcidx 2 (defined)
  (table 4 funcref)
  ;; MIXED active elem on table 0: imported ef0 @0, defined @1, imported ef1 @2 (slot ABI unchanged);
  ;; slot 3 left null.
  (elem (i32.const 0) $ef0 $defined $ef1)

  ;; via_ci(i,x): call_indirect slot i — reaches an IMPORTED funcref at i∈{0,2}, the DEFINED at i=1.
  (func (export "via_ci") (param $i i32) (param $x i32) (result i32)
    (local.get $x) (local.get $i) (call_indirect (type $unary)))
  ;; direct(x): the oracle — a DIRECT call of the same import ef0. Spec: via_ci(0,x) == direct(x).
  (func (export "direct") (param $x i32) (result i32) (call $ef0 (local.get $x)))

  ;; the 3 ordered fail-closed guards on import-routed slots (same traps + order as call_indirect):
  (func (export "ci_oob")  (param $x i32) (result i32)     ;; idx 9 ≥ size 4 → undefined element
    (local.get $x) (i32.const 9) (call_indirect (type $unary)))
  (func (export "ci_null") (param $x i32) (result i32)     ;; slot 3 present-but-null → uninitialized
    (local.get $x) (i32.const 3) (call_indirect (type $unary)))
  (func (export "ci_type") (param $x i32) (result i32)     ;; slot 0 is $unary; call as binary → mismatch
    (local.get $x) (local.get $x) (i32.const 0) (call_indirect (type $binary))))
