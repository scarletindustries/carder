;; mem64 — the memory64 RUNTIME backstop (capstone P6-11, proof 2, I4/S9). A 64-bit-addressed
;; linear memory: i64 address operands, an address past 2^32 (4 GiB), memory.size/grow in i64
;; page counts, a grow beyond the documented spec-aligned page cap (Binding.mem64_max_pages =
;; 2^32 pages) → -1, and an access beyond the current size → trap. 32-bit memories stay byte-
;; identical (proof 4). The paged backend grows on demand (sparse), so the cap is a trap boundary,
;; not a reservation. Cross-checked vs wasmtime 46.0.1 for the runnable behaviours.
(module
  (memory i64 1)
  (func (export "size") (result i64) (memory.size))
  ;; grow by 2^32 pages — exceeds the mem64 page cap (2^32) → -1, allocates nothing.
  (func (export "grow_over") (result i64) (memory.grow (i64.const 4294967296)))
  ;; grow by 65537 pages → new size 65538, past the i32 4 GiB ceiling (O(1) sparse watermark).
  (func (export "grow_big") (result i64) (memory.grow (i64.const 65537)))
  ;; store an i64 at byte 2^32 + 40 and load it back — i64 addressing past 4 GiB.
  (func (export "st_ld") (result i64)
    (i64.store (i64.const 4294967336) (i64.const 81985529216486895))
    (i64.load (i64.const 4294967336)))
  ;; a freshly-grown region past 2^32 reads as zero (sparse, no allocation).
  (func (export "load_hi") (result i64) (i64.load (i64.const 4294967296)))
  ;; a load at byte_len (65538*65536 = 4295098368) is beyond the current size → trap.
  (func (export "oob") (result i64) (i64.load (i64.const 4295098368))))
