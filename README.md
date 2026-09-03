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
├── ci.ps1                      # Verification entry point / commit gate
├── .githooks/
│   └── pre-commit              # Runs ci.ps1; installed with ci.ps1 -InstallHook
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
│   ├── build_win_link_inputs.ps1 # Generates the Windows link inputs from bundled Zig
│   └── prepare_offline_release.ps1 # Builds the customer offline payload
├── test/                       # Test suites, all run by ci.ps1
└── tools/                     # All toolchain binaries (git-ignored binaries)
    ├── cargo-home/            # CARGO_HOME
    ├── rustup-home/           # RUSTUP_HOME
    ├── rustup/                # rustup launcher copy
    ├── zig/                   # Zig compiler
    ├── zig-global-cache/      # ZIG_GLOBAL_CACHE_DIR
    ├── zig-local-cache/       # ZIG_LOCAL_CACHE_DIR
    ├── wrappers/              # zig-cc wrapper .cmd files
    ├── sysroot/               # Generated Windows link inputs (import libs + shim)
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
It needs no Visual Studio, MSVC linker or Windows SDK: the Windows import libraries it links against
ship in `tools/sysroot/x86_64-pc-windows-msvc/lib/` and are passed ahead of any host library path, so
the build behaves the same with or without Visual Studio installed. The produced executables run on
Windows 10 / Server 2016 and later and need no Visual C++ redistributable.

A crate whose C code requires Microsoft's own headers rather than the bundled mingw-w64 ones is the one
remaining case that still needs a host MSVC installation; it fails in the C build script, not at link
time. C code that calls the wide-character printf or scanf family is the one known link-time gap - see
`build_win_link_inputs.ps1` below.

### `build_win_link_inputs.ps1`

Regenerates `tools/sysroot/x86_64-pc-windows-msvc/` from the bundled Zig installation - import
libraries built from mingw-w64 module-definition files, plus `rpc_winshim.lib` for the handful of
symbols no Windows DLL exports. It needs no network access and no Microsoft tooling, and it runs
automatically as part of `prepare_offline_release.ps1`.

`rpc_winshim.lib` covers two kinds of symbol that nothing on an MSVC link line defines.

The first is the stack probe, under both names it is called by. MSVC codegen calls it `__chkstk`;
the bundled C compiler targets the GNU ABI, so for any frame larger than one page it calls libgcc's
`___chkstk_ms` instead. They are the same routine, and neither libgcc nor compiler-rt is on an MSVC
link line, so both names are labels on one body in the shim.

The second is formatted I/O. `ucrtbase.dll` exports the `__stdio_common_v*` primitives but not one
member of the printf or scanf family - in Microsoft's own headers those are inline bodies that
forward to the primitives, so they never become DLL exports, and mingw leaves the bodies to
`libmingwex.a`. The shim carries them instead: `printf`, `fprintf`, `sprintf`, `snprintf`,
`_snprintf`, `_scprintf`, `scanf`, `fscanf`, `sscanf` and each one's `v`-prefixed variant, each with
the option flags its Microsoft header inline passes. The wide-character families are absent from
`ucrtbase.dll` too and are deliberately not shimmed; add them to the symbol list if a dependency
ever needs them.

The shim also provides `mainCRTStartup`, `_fltused`, `atexit` and the TLS directory. The full set
the generator asserts is declared in `$script:RequiredShimSymbols` and recorded in the sysroot's
`PROVENANCE.json`; `check_tool_x64_win.ps1` verifies the shipped archive against that record.

```powershell
.\scripts\build_win_link_inputs.ps1 -Force
```

### `check_tool_x64_win.ps1`

Verifies that an `x86_64-pc-windows-msvc` build is genuinely self-contained: it builds with the host
Visual Studio environment scrubbed, runs the results, and fails if any library the linker resolved came
from outside the toolkit root. `prepare_offline_release.ps1` runs it and refuses to package on failure.

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

## Running Tests and the Commit Gate

`ci.ps1` is the single verification entry point. It runs the repository's checks concurrently and exits
non-zero if any of them fails, reporting every failure in one run rather than stopping at the first.

```powershell
.\ci.ps1          # default lane: about 12 s, and needs no installed toolchain
.\ci.ps1 -Full    # adds the four check_tool_*.ps1 cross builds (minutes, needs tools\)
```

The default lane runs:

| Check | What it covers |
|---|---|
| `powershell-syntax` | Every tracked `.ps1` parses |
| `test/*.tests.ps1` | Each suite under `test\`, discovered rather than listed |
| `openspec-validate` | `openspec validate --all --strict` over the OpenSpec artifacts |

A check whose prerequisite is missing reports `SKIP` with the reason - a skip is not a pass, and the
verdict says how many checks did not run. Because the gate verifies the working tree rather than the
staged content, it warns when tracked files have unstaged changes.

Individual suites can still be run directly:

```powershell
pwsh -NoProfile -File .	estust_setup.tests.ps1
```

### Hooking the gate to `git commit`

```powershell
.\ci.ps1 -InstallHook
```

This points the clone's `core.hooksPath` at the version-controlled `.githooks\`, so `git commit` runs
the default lane and refuses the commit when it fails. Because the hook is version-controlled, a fix to
it arrives with a normal `git pull` instead of needing a re-install.

It is a per-clone opt-in: git configuration cannot be set by a checkout, so each developer runs it once.
Installing again is a no-op. The installer refuses to overwrite a `core.hooksPath` it did not set, since
that setting replaces `.git\hooks` wholesale and overwriting it would silently disable whatever hooks
that path provides.

| Bypass | Effect |
|---|---|
| `git commit --no-verify` | Skips the gate for one commit |
| `$env:RUST_PORTABLE_CROSS_SKIP_CI = "1"` | Skips the gate for scripted or automated commits |
| `git config --unset core.hooksPath` | Uninstalls the gate from this clone |

The gate also skips itself while a merge or rebase is in progress, so it never stands between you and a
conflict resolution. Every skip says so on its own line rather than reporting a pass.


---

## Sample Project

A minimal project is provided in `sample/` to verify the cross-compilation pipeline:

```powershell
. .\scripts\rust_env.ps1
cd sample
..\scripts\rust_build_aarch64.ps1
```
