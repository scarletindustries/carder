;; Acceptance #7a — a module whose `start` function traps FAILS to instantiate.
;; The generated `instantiate/0` runs `start` last (spec exec/modules.html); an
;; `unreachable` there raises, so instantiation fails (=> trap unreachable).
(module
  (func $boom (unreachable))
  (start $boom)
  (func (export "noop")))
