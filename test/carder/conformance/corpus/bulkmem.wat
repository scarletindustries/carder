;; bulkmem — bulk memory instructions (memory.fill/copy/init + data.drop), eager-bounds trap
;; (no partial write) and memmove-correct overlap.
;; Spec: https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions
(module
  (memory 1)
  (data $d "abcd")  ;; passive data segment
  (func (export "load8") (param i32) (result i32) (local.get 0) (i32.load8_u))
  (func (export "fill") (param i32 i32 i32)
    (local.get 0) (local.get 1) (local.get 2) (memory.fill))
  (func (export "copy") (param i32 i32 i32)
    (local.get 0) (local.get 1) (local.get 2) (memory.copy))
  (func (export "init") (param i32 i32 i32)
    (local.get 0) (local.get 1) (local.get 2) (memory.init $d))
  (func (export "dropd") (data.drop $d)))
