# rust-portable-cross

A portable, self-contained Rust cross-compilation toolkit for Windows. All toolchain components (rustup, cargo, rustc, Zig) are installed into the repository-local `tools/` directory and do **not** touch your system-wide Rust installation or PATH.

Supported cross-compilation targets:

| Target | Description |
|---|---|
| `armv7-unknown-linux-musleabihf` | ARMv7 Linux (musl libc, hard-float) |
| `aarch64-unknown-linux-musl` | AArch64 / ARM64 Linux (musl libc) |
| `x86_64-pc-windows-msvc` | Windows x64 (host, native) |

Cross-compilation is powered by [Zig](https://ziglang.org/) acting as the C linker, eliminating the need for a separate Linux cross-toolchain.

---

## Prerequisites

- Windows 10 / Windows Server 2019 or later (x86-64)
- PowerShell 5.1 or PowerShell 7+
- Internet access (or configured mirrors/proxy — see [Download Configuration](#download-configuration))

---

## Quick Start

### 1. First-time setup

Run once from the repository root to download and install all toolchain components:

```powershell
.\scripts\rust_setup.ps1
```

This will:
- Download `rustup-init.exe` and install the `stable-x86_64-pc-windows-msvc` toolchain into `tools/`
- Add the `armv7-unknown-linux-musleabihf` and `aarch64-unknown-linux-musl` targets
- Download and extract Zig 0.13.0 into `tools/zig/`
- Generate Zig-based cross-compiler wrapper scripts in `tools/wrappers/`

Use `-Force` to reset cached registry/package data and re-run setup:

```powershell
.\scripts\rust_setup.ps1 -Force
```

### 2. Activate the environment

Run in every new terminal session before building:

```powershell
. .\scripts\rust_env.ps1
```

This sets `CARGO_HOME`, `RUSTUP_HOME`, `ZIG_*` cache paths, and prepends the toolkit binaries to `PATH`.

### 3. Cross-compile your project

Change into your Rust project directory, then run the target-specific build script:

```powershell
# Build for AArch64 Linux (musl)
cd my_project
. D:\rust-portable-cross\scripts\rust_env.ps1
rust_build_aarch64.ps1
```

```powershell
# Build for ARMv7 Linux (musl)
cd my_project
. D:\rust-portable-cross\scripts\rust_env.ps1
rust_build_armv7.ps1
```

Build outputs are placed under `target/<triple>/release/` inside your project directory.

---

## Repository Layout

```
rust-portable-cross/
├── config/
│   └── .cargo/
│       └── config.toml        # Cargo linker config for cross targets
├── sample/                    # Minimal sample Rust project
│   ├── Cargo.toml
│   └── src/main.rs
├── scripts/
│   ├── rust_setup.ps1         # One-time toolchain installation
│   ├── rust_env.ps1           # Environment activation (dot-source)
│   ├── rust_build_aarch64.ps1 # Cross-build for aarch64-unknown-linux-musl
│   ├── rust_build_armv7.ps1   # Cross-build for armv7-unknown-linux-musleabihf
│   └── rust_setup.tests.ps1   # Unit tests for setup script logic
└── tools/                     # All toolchain binaries (git-ignored binaries)
    ├── cargo-home/            # CARGO_HOME
    ├── rustup-home/           # RUSTUP_HOME
    ├── rustup/                # rustup launcher copy
    ├── zig/                   # Zig compiler
    ├── zig-global-cache/      # ZIG_GLOBAL_CACHE_DIR
    ├── zig-local-cache/       # ZIG_LOCAL_CACHE_DIR
    ├── wrappers/              # zig-cc wrapper .cmd files
    └── downloads/             # Downloaded installer cache
```

---

## Scripts Reference

### `rust_setup.ps1`

```
.\scripts\rust_setup.ps1 [-Force]
```

| Parameter | Description |
|---|---|
| `-Force` | Clears cached Cargo registry/git data before re-running setup |

### `rust_env.ps1`

Must be **dot-sourced** so that environment variables are set in the calling session:

```powershell
. .\scripts\rust_env.ps1
```

Exports: `RUST_PORTABLE_CROSS_ROOT`, `CARGO_HOME`, `RUSTUP_HOME`, `RUSTUP_TOOLCHAIN`, `ZIG_LOCAL_CACHE_DIR`, `ZIG_GLOBAL_CACHE_DIR`, `CC_armv7_*`, `CC_aarch64_*`, and updates `PATH`.

### `rust_build_aarch64.ps1` / `rust_build_armv7.ps1`

Run from inside a Rust project directory (must contain `Cargo.toml`). Copies `config/.cargo/config.toml` into the project's `.cargo/` before invoking `cargo build --release`.

---

## Download Configuration

The setup script supports flexible download source configuration via environment variables. The resolution order is:

1. **Direct override URL** (`RUST_PORTABLE_CROSS_RUSTUP_INIT_URL` / `RUST_PORTABLE_CROSS_ZIG_URL`)
2. **Mainland mirror list** (`RUST_PORTABLE_CROSS_RUSTUP_MIRRORS` / `RUST_PORTABLE_CROSS_ZIG_MIRRORS`)
3. **Mirror base URL** (`RUST_PORTABLE_CROSS_RUSTUP_MIRROR_BASE` / `RUST_PORTABLE_CROSS_ZIG_MIRROR_BASE`)
4. **Proxy prefix** (`RUST_PORTABLE_CROSS_DOWNLOAD_PROXY_PREFIX`)
5. Official upstream (automatic fallback)

| Variable | Description |
|---|---|
| `RUST_PORTABLE_CROSS_RUSTUP_INIT_URL` | Direct URL for `rustup-init.exe` |
| `RUST_PORTABLE_CROSS_ZIG_URL` | Direct URL for the Zig zip archive |
| `RUST_PORTABLE_CROSS_RUSTUP_MIRRORS` | Semicolon/comma/newline-separated mirror URLs for rustup |
| `RUST_PORTABLE_CROSS_ZIG_MIRRORS` | Semicolon/comma/newline-separated mirror URLs for Zig |
| `RUST_PORTABLE_CROSS_RUSTUP_MIRROR_BASE` | Mirror base URL joined with the built-in relative path |
| `RUST_PORTABLE_CROSS_ZIG_MIRROR_BASE` | Mirror base URL joined with the built-in relative path |
| `RUST_PORTABLE_CROSS_DOWNLOAD_PROXY_PREFIX` | Proxy prefix prepended to the official upstream URL |
| `RUST_PORTABLE_CROSS_WGET_PATH` | Absolute path to a `wget` executable (download backend override) |
| `RUST_PORTABLE_CROSS_DOWNLOAD_RETRIES` | Retry count for wget/curl backends (default: 6) |
| `RUST_PORTABLE_CROSS_CURL_IP_MODE` | Force curl IP mode: `4`, `6`, or `auto` |

By default, `RUSTUP_DIST_SERVER` is set to `https://rsproxy.cn` and `RUSTUP_UPDATE_ROOT` to `https://rsproxy.cn/rustup` to improve download reliability from mainland China. These can be overridden by setting the variables before running setup.

---

## Running Tests

```powershell
.\scripts\rust_setup.tests.ps1
```

Tests cover internal helper functions (path resolution, URI list construction, mirror logic) without executing the full setup.

---

## Sample Project

A minimal project is provided in `sample/` to verify the cross-compilation pipeline:

```powershell
. .\scripts\rust_env.ps1
cd sample
..\scripts\rust_build_aarch64.ps1
```
