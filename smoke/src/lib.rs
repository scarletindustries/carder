//! Smoke-test surface for carder: real external crates (CRC-32, SHA-256, DEFLATE)
//! compiled to a no-import, MVP-only wasm, exercised via i32-in/i32-out exports so
//! carder (compile → .beam → run) can be differential-tested against wasmtime.
#![no_std]
extern crate alloc;
use alloc::vec::Vec;

#[global_allocator]
static ALLOC: dlmalloc::GlobalDlmalloc = dlmalloc::GlobalDlmalloc;
#[panic_handler]
fn ph(_: &core::panic::PanicInfo) -> ! { loop {} }

/// n deterministic pseudo-random bytes (a linear congruential generator).
fn gen(n: u32) -> Vec<u8> {
    let mut v = Vec::with_capacity(n as usize);
    let mut s: u32 = 0x1234_5678;
    for _ in 0..n {
        s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        v.push((s >> 24) as u8);
    }
    v
}

/// CRC-32 (IEEE) of n deterministic bytes.
#[no_mangle]
pub extern "C" fn crc32(n: u32) -> u32 { crc32fast::hash(&gen(n)) }

/// First 4 big-endian bytes of SHA-256 of n deterministic bytes.
#[no_mangle]
pub extern "C" fn sha256_word(n: u32) -> u32 {
    use sha2::{Digest, Sha256};
    let h = Sha256::digest(gen(n));
    u32::from_be_bytes([h[0], h[1], h[2], h[3]])
}

/// Full DEFLATE roundtrip on n bytes: compress → decompress → verify equal;
/// returns the CRC-32 of the *compressed* stream (0 on roundtrip failure).
/// Exercises the allocator + real compression + decompression end-to-end.
#[no_mangle]
pub extern "C" fn deflate_roundtrip(n: u32) -> u32 {
    let data = gen(n);
    let comp = miniz_oxide::deflate::compress_to_vec(&data, 6);
    match miniz_oxide::inflate::decompress_to_vec(&comp) {
        Ok(dec) if dec == data => crc32fast::hash(&comp),
        _ => 0,
    }
}
