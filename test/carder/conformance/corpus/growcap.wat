;; Acceptance #4 (Safe cap) — a memory with NO declared max, so the Safe-profile hard
;; max-pages cap governs (E3). Compiled with a LOW-cap Binding (profiles.safe_capped),
;; a grow past the cap returns -1 and allocates nothing — proving untrusted code cannot
;; allocate unboundedly even when it declares max_pages: None.
(module
  (memory 0)                                      ;; min 0 pages, NO declared max
  (func (export "size") (result i32) (memory.size))
  (func (export "grow") (param i32) (result i32) (memory.grow (local.get 0))))
