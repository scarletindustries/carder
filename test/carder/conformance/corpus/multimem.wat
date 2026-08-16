;; multimem — two linear memories: independent regions + a memory.copy ACROSS memories.
;; Every memory op carries a memory index (H3). Spec: multi-memory proposal.
(module
  (memory $a 1)
  (memory $b 1)
  (func (export "store_b") (param i32 i32) (local.get 0) (local.get 1) (i32.store $b))
  (func (export "load_a") (param i32) (result i32) (local.get 0) (i32.load $a))
  (func (export "load_b") (param i32) (result i32) (local.get 0) (i32.load $b))
  (func (export "copy_b_to_a") (param i32 i32 i32)
    (local.get 0) (local.get 1) (local.get 2) (memory.copy $a $b)))
