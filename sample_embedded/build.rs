//! Make the bundled linker script (`link.x`) visible to the linker.
//!
//! `link.x` is copied into the Cargo `OUT_DIR`, which is then added to the
//! linker search path. Combined with `-C link-arg=-Tlink.x` (set in
//! `.cargo/config.toml`) this lets rust-lld find the script no matter where
//! the crate is built from. This mirrors how `cortex-m-rt` ships its own
//! linker script.

use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR not set"));
    fs::write(out_dir.join("link.x"), include_bytes!("link.x"))
        .expect("failed to write link.x to OUT_DIR");

    println!("cargo:rustc-link-search={}", out_dir.display());
    println!("cargo:rerun-if-changed=link.x");
    println!("cargo:rerun-if-changed=build.rs");
}
