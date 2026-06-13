#![no_std]

//! Minimal bare-metal smoke test for the `thumbv7em-none-eabihf` target.
//!
//! This crate touches `core` only — no `std`, no allocator, no external
//! dependencies — so it builds completely offline as an `rlib`. Compiling it
//! proves the installed `rust-std-thumbv7em-none-eabihf` component works
//! without requiring a `memory.x` linker script or a final link step.

/// A tiny rotate-and-xor checksum over a byte slice.
///
/// Pure `core`, no heap, no panics on valid input — representative of the kind
/// of code an embedded firmware crate compiles for this target.
pub fn checksum(data: &[u8]) -> u32 {
    let mut acc: u32 = 0;
    for &byte in data {
        acc = acc.rotate_left(1) ^ u32::from(byte);
    }
    acc
}

/// Saturating sum, useful as a second trivially-verifiable `core` routine.
pub fn saturating_total(values: &[u8]) -> u32 {
    let mut total: u32 = 0;
    for &value in values {
        total = total.saturating_add(u32::from(value));
    }
    total
}
