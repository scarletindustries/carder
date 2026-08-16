;; A host import under deny-all — must be REJECTED end-to-end (D9/D4), fail-closed.
;; (The Phase-1 decoder does not model the import section, so this module cannot be
;; faithfully compiled to a runnable instance: the export's funcidx falls out of range
;; once imports are absent, and the pipeline rejects it with a typed error rather than
;; silently producing a wrong-but-running module.)
(module
  (import "env" "forbidden" (func $f (param i32) (result i32)))
  (func (export "useimport") (param i32) (result i32)
    (call $f (local.get 0))))
