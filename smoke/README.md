# carder smoke test — real programs on the BEAM

An end-to-end smoke test that takes **real, external, permissively-licensed libraries**,
compiles their source to a **no-import, MVP-only WebAssembly** module, runs it through the
full carder pipeline (`decode → validate → lower → IR → Core Erlang → .beam → instantiate →
invoke`), and **differential-tests every result against `wasmtime`**.

```sh
./smoke/run.sh
```

## What it runs

Three widely-used crates (their source is fetched by `cargo` and statically linked into one
import-free wasm), exposed as `i32`-in / `i32`-out exports:

| Export | Crate | License | Exercises |
|---|---|---|---|
| `crc32(n)` | [`crc32fast`](https://crates.io/crates/crc32fast) | MIT/Apache-2.0 | table-driven CRC-32, memory |
| `sha256_word(n)` | [`sha2`](https://crates.io/crates/sha2) | MIT/Apache-2.0 | SHA-256 (64-round compression, rotations, message schedule) |
| `deflate_roundtrip(n)` | [`miniz_oxide`](https://crates.io/crates/miniz_oxide) | MIT/Zlib/Apache-2.0 | **real DEFLATE compress + decompress + verify**, the `dlmalloc` allocator, `memory.grow`, heavy memory traffic |

The allocator is [`dlmalloc`](https://crates.io/crates/dlmalloc) (MIT/Apache-2.0), which is
import-free (it grows linear memory itself).

## Result

All exports produce **bit-exact** results vs `wasmtime` on the BEAM — including a full
DEFLATE compress/decompress roundtrip of 2000 bytes. The wasm is ~73 KB / ~80 functions,
**0 imports**, and validates as `wasm1 + mutable-globals` (pure MVP).

```
crc32 4096               carder=2538352202  wasmtime=2538352202  ok
sha256_word 4096         carder=2927598936  wasmtime=2927598936  ok
deflate_roundtrip 2000   carder=2010787627  wasmtime=2010787627  ok   (compress+decompress on the BEAM)
```

## The toolchain (how to add more targets)

carder supports the **WASM 1.0 MVP only, with no imports** (see the repo README). So a smoke
target must be import-free and avoid bulk-memory / reference-types / SIMD / threads.

- **Rust** (used here): the `wasm32v1-none` target (stable since Rust 1.84) emits pure
  wasm-1.0 + mutable-globals — no reference-types or bulk-memory to strip. Use `#![no_std]`
  + `extern crate alloc` + a `#[global_allocator]` (`dlmalloc`), `crate-type = ["cdylib"]`,
  `panic = "abort"`, and `#[no_mangle] pub extern "C"` exports.
  Build: `cargo build --release --target wasm32v1-none`.
- **C**: Apple clang has no wasm backend — use Homebrew LLVM (`brew install llvm lld`):
  `clang --target=wasm32 -mcpu=mvp -msign-ext -mnontrapping-fptoint -mmultivalue -nostdlib
  -ffreestanding -fno-builtin -O2 -Wl,--no-entry -Wl,--export-all -o out.wasm prog.c`.
  `-mcpu=mvp` is essential: LLVM ≥19 enables `reference-types`/`bulk-memory` by default,
  which emit opcodes/encodings carder doesn't support. Provide `memcpy`/`memset`/`memmove`/
  `memcmp` as plain C so they don't become `memory.copy`/`memory.fill`.

Gate any candidate before feeding carder:
```sh
wasm-tools print x.wasm | grep -c '(import'                                   # must be 0
wasm-tools print x.wasm | grep -cE 'memory\.(copy|fill|init)|data\.drop|v128' # must be 0
wasm-tools validate --features=wasm1,mutable-global x.wasm
```

## SQLite — the north-star (feasible to build; a real carder stress test)

SQLite is **public domain** (free to clone, build, run, redistribute). A no-import,
MVP-only, self-contained `sqlite.wasm` **is buildable** via SQLite's officially-supported
freestanding path — `-DSQLITE_OS_OTHER=1 -DSQLITE_THREADSAFE=0`, an in-memory VFS,
`-DSQLITE_ENABLE_MEMSYS5` (a static heap, so no `malloc`), built with `-mno-bulk-memory` +
loop-based `memcpy`/`memset`. There is working prior art
([`sqlite-wasm-rs`](https://github.com/Spxg/sqlite-wasm-rs) ships essentially this artifact).

It is **not yet a passing smoke test**, for two reasons worth tracking:
1. The clean build must force `-mno-bulk-memory` and supply the libc subset SQLite needs
   (a ~0.5–2 day build effort cribbing the musl subset + memvfs shim).
2. The result is ~1 MB / thousands of functions with a few very large functions and a big
   active data segment. carder's atom/function-count scaling is fine, but it would stress the
   single-module `compile:forms` on the giant functions and the paged-immutable-binary
   memory on SQLite's memcpy/memset-heavy code (each byte-store rebuilds a 4 KB chunk).

So SQLite is a genuine **north-star**: reaching it motivates concrete carder work
(bulk-memory lowering, compact data-segment emission, possibly multi-module output). The
crate ladder above is the calibrated stepping stone that passes today.
