;; Acceptance #7b — an OUT-OF-BOUNDS active data segment FAILS to instantiate.
;; Instantiation bounds-checks each active data segment's [offset, offset+len) against the
;; memory size; here offset 65534 + 4 bytes = 65538 > 65536, so it aborts instantiation
;; (=> trap out of bounds memory access) with no partial write (spec exec/modules.html).
(module
  (memory 1)
  (data (i32.const 65534) "\01\02\03\04")
  (func (export "noop")))
