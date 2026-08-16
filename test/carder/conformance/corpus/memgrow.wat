;; Acceptance #4 — memory.grow / memory.size growth semantics + the DECLARED-max cap.
;; Proves: memory.grow(d) returns the OLD size in pages; memory.size reflects the growth;
;; a grow past the declared max returns -1 (0xFFFFFFFF) and allocates NOTHING (size is
;; unchanged). The Safe-profile resource cap (a module with NO declared max that grows past
;; safe_max_pages) is proven separately in corpus_test with a low-cap Binding.
(module
  (memory 0 1)                                    ;; min 0 pages, declared max 1 page
  (func (export "size") (result i32) (memory.size))
  (func (export "grow") (param i32) (result i32) (memory.grow (local.get 0))))
