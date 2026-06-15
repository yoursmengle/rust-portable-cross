# rust-portable-cross

A portable, self-contained Rust cross-compilation toolkit for Windows. All toolchain components (rustup, cargo, rustc, Zig) are installed into the repository-local `tools/` directory and do **not** touch your system-wide Rust installation or PATH.

Supported cross-compilation targets:

| Target | Description |
|---|---|
| `armv7-unknown-linux-musleabihf` | ARMv7 Linux (musl libc, hard-float) |
| `aarch64-unknown-linux-musl` | AArch64 / ARM64 Linux (musl libc) |
| `thumbv7em-none-eabihf` | ARM Cortex-M4F/M7 bare-metal (`no_std`, hard-float) |

The Linux targets are powered by [Zig](https://ziglang.org/) acting as the C linker, eliminating the need for host-installed GCC/Clang cross-toolchains. The bare-metal `thumbv7em-none-eabihf` target links with the bundled `rust-lld` and needs no Zig wrapper or external C toolchain.

---

## Prerequisites

- Windows 10 / Windows Server 2019 or later (x86-64)
- PowerShell 5.1 or PowerShell 7+
- Internet access (or configured mirrors/proxy — see [Download Configuration](#download-configuration))

---

## Quick Start

### 1. Internal first-time setup

Run once from the repository root to download and install all toolchain components:

```powershell
.\scripts\rust_setup.ps1
```

This will:
- Download `rustup-init.exe` and install the `stable-x86_64-pc-windows-msvc` toolchain into `tools/`
- Add the `armv7-unknown-linux-musleabihf`, `aarch64-unknown-linux-musl`, and `thumbv7em-none-eabihf` targets
- Download and extract Zig 0.13.0 into `tools/zig/`
- Generate Zig-based cross-compiler wrapper scripts in `tools/wrappers/`

Use `-Force` to reset cached registry/package data and re-run setup:

```powershell
.\scripts\rust_setup.ps1 -Force
```

### Customer offline installer flow

Customer delivery should use the offline installer generated from the staged release payload, not `rust_setup.ps1`.

- installer source: `packaging/inno/rust_portable_cross.iss`
- staging script: `scripts/prepare_offline_release.ps1`
- customer guide: `docs/customer/README-offline.md`

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

```powershell
# Build for ARM Cortex-M4F/M7 bare metal (no_std)
cd my_firmware_project
. D:\rust-portable-cross\scripts\rust_env.ps1
rust_build_thumbv7em.ps1
```

Build outputs are placed under `target/<triple>/release/` inside your project directory.

> **Note:** `thumbv7em-none-eabihf` is a bare-metal `no_std` target, so a
> firmware binary needs its own linker script. The bundled `sample_embedded`
> crate is a complete, dependency-free example for the HEM6801E board
> (GD32F427ZE): it ships its own `link.x`, links with `rust-lld`, and its
> `make_image.ps1` emits a downloadable `.bin`/`.hex` (via the bundled
> `rust-objcopy`) for the active-app slot at `0x08008000`. See
> `sample_embedded/README.md`.

---

## Repository Layout

```
rust-portable-cross/
├── config/
│   └── .cargo/
│       └── config.toml        # Cargo linker config for supported targets
├── sample/                    # Minimal sample Rust project (std)
│   ├── Cargo.toml
│   └── src/main.rs
├── sample_embedded/           # Flashable no_std firmware for the HEM6801E board
│   ├── Cargo.toml             #   (GD32F427ZE, Cortex-M4F)
│   ├── .cargo/config.toml     # Target + linker-script flags
│   ├── build.rs               # Puts link.x on the linker search path
│   ├── link.x                 # Memory map (app @ 0x08008000) + vector table
│   ├── make_image.ps1         # Build + emit downloadable .bin / .hex
│   ├── README.md              # Board wiring, build and flashing notes
│   └── src/
│       ├── main.rs            # Vector table, reset, D16/D17 1 Hz blink
│       └── lib.rs             # core-only smoke-test routines
├── scripts/
│   ├── rust_setup.ps1          # One-time toolchain installation
│   ├── rust_env.ps1            # Environment activation (dot-source)
│   ├── rust_build_aarch64.ps1  # Cross-build for aarch64-unknown-linux-musl
│   ├── rust_build_armv7.ps1    # Cross-build for armv7-unknown-linux-musleabihf
│   ├── rust_build_thumbv7em.ps1 # Bare-metal build for thumbv7em-none-eabihf
│   └── rust_setup.tests.ps1    # Unit tests for setup script logic
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

### `rust_build_aarch64.ps1` / `rust_build_armv7.ps1` / `rust_build_thumbv7em.ps1`

Run from inside a Rust project directory (must contain `Cargo.toml`). Copies `config/.cargo/config.toml` into the project's `.cargo/` before invoking `cargo build --release`. `rust_build_thumbv7em.ps1` builds the bare-metal `thumbv7em-none-eabihf` target with the bundled `rust-lld`; it sets up no Zig/C cross-toolchain.

If you want to build `x86_64-pc-windows-msvc` without installing system Rust, use:

```powershell
.\scripts\rust_build_x64_win_native.ps1 -ProjectPath D:\path\to\your\project
```

This helper wires `rust-lld` and a repository-local Zig C compiler wrapper for crates that use `cc-rs`.

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
