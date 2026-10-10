# rust-portable-cross

**English** | [简体中文](README.zh-CN.md)

A portable, self-contained Rust cross-compilation toolkit for Windows.

Build Rust programs for ARM Linux boards, ARM64 Linux boards, Cortex-M microcontrollers and Windows
itself from one Windows machine, with no Visual Studio, no Windows SDK, no GCC cross-toolchain and no
system-wide Rust installation. Everything lives in one directory that you can copy, move or delete.

- **Self-contained.** rustup, cargo, rustc and Zig are installed under the toolkit's own `tools/`
  directory. Your system `PATH`, registry and any existing Rust installation are left alone.
- **No C toolchain to install.** [Zig](https://ziglang.org/) acts as the C compiler and linker for the
  Linux targets, and the toolkit ships its own Windows link inputs for host builds.
- **Works offline.** A release is a single offline installer; after installation, builds need no
  network access. The bundled sample's dependencies are included.
- **Pinned and verified.** The Rust and Zig versions are fixed, downloads are checked against
  recorded SHA-256 digests, and every shipped file is covered by an integrity index.
- **Relocatable.** Move the directory and activate it again; nothing else needs to change.

## Contents

- [Supported targets](#supported-targets)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Using the toolkit in your own project](#using-the-toolkit-in-your-own-project)
- [Sample projects](#sample-projects)
- [How it works](#how-it-works)
- [Scripts reference](#scripts-reference)
- [Download configuration](#download-configuration)
- [Building a release](#building-a-release)
- [Development](#development)
- [Repository layout](#repository-layout)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Contributing](#contributing)
- [License](#license)

## Supported targets

| Target | Platform | Build script | Linker |
|---|---|---|---|
| `armv7-unknown-linux-musleabihf` | ARMv7 Linux, musl libc, hard-float | `scripts/rust_build_armv7.ps1` | Zig |
| `aarch64-unknown-linux-musl` | ARM64 Linux, musl libc | `scripts/rust_build_aarch64.ps1` | Zig |
| `thumbv7em-none-eabihf` | ARM Cortex-M4F / M7 bare metal (`no_std`), hard-float | `scripts/rust_build_thumbv7em.ps1` | `rust-lld` |
| `x86_64-pc-windows-msvc` | Windows x64 (the host) | `scripts/rust_build_x64_win_native.ps1` | `rust-lld` |

The Linux targets produce statically linked musl binaries that run on the board without any runtime
libraries. Windows executables run on Windows 10 / Server 2016 and later and need no Visual C++
redistributable.

Pinned versions: Rust `1.98.0` (host toolchain `1.98.0-x86_64-pc-windows-msvc`) and Zig `0.13.0`.

## Requirements

- Windows 10 / Windows Server 2019 or later, x86-64
- PowerShell 5.1 or PowerShell 7+
- About 2 GB of free disk space for the installed toolkit, plus space for your build output
- Internet access for the from-source setup only (mirrors and proxies are supported, see
  [Download configuration](#download-configuration)); the offline installer needs none

Not required: Visual Studio, the MSVC linker, the Windows SDK, a system Rust installation, or any GCC /
Clang cross-toolchain.

## Installation

There are two ways to get a working toolkit. Use the offline installer to *use* the toolkit; set it up
from source to *develop* it or to build your own installer.

### Option A: offline installer

Run `rust-portable-cross-offline-<version>.exe`. It downloads nothing.

- It installs for the current user by default; an all-users installation is offered in the dialog.
- The default location is `D:\rust-portable-cross` when a `D:` drive exists, otherwise
  `C:\rust-portable-cross`.
- All four targets are installed together.

After installation, open **Activate Rust Portable Cross (PowerShell)** from the Start menu. The
customer-facing guide that ships with the installer is `docs/customer/README-offline.md`.

To produce the installer yourself, see [Building a release](#building-a-release).

### Option B: from source

Clone the repository and run the setup script once from its root:

```powershell
git clone https://gitee.com/yoursmengle/rust-portable-cross.git
cd rust-portable-cross
.\scripts\rust_setup.ps1
```

Setup:

- downloads `rustup-init.exe` and installs the pinned Rust toolchain into `tools/`,
- adds the three cross targets,
- downloads Zig, checks it against the recorded digest, and removes the parts of its library that
  belong to platforms the toolkit does not target,
- generates the Zig-based compiler wrappers in `tools/wrappers/`,
- generates the Windows link inputs in `tools/sysroot/x86_64-pc-windows-msvc/`,
- verifies the installed tools and target libraries.

Setup is safe to run again. `.\scripts\rust_setup.ps1 -Force` also clears cached registry and package
data first.

## Quick start

Activate the toolkit in each new PowerShell session, then run a build script from inside a Rust
project. The examples assume the toolkit is at `D:\rust-portable-cross`.

```powershell
# 1. Activate (note the leading dot: the script must be dot-sourced)
. D:\rust-portable-cross\scripts\rust_env.ps1

# 2. Build the bundled sample for ARM64 Linux
cd D:\rust-portable-cross\sample
rust_build_aarch64.ps1

# 3. The result is a static Linux binary
dir target\aarch64-unknown-linux-musl\release\sample
```

The same pattern works for the other targets:

```powershell
rust_build_armv7.ps1                                  # ARMv7 Linux
rust_build_thumbv7em.ps1                              # Cortex-M4F / M7 firmware
rust_build_x64_win_native.ps1 -ProjectPath .          # Windows x64
```

Build output goes to `target/<triple>/release/` inside your project. Each build script builds in
release mode; `rust_build_x64_win_native.ps1` also accepts `-DebugBuild`.

To check that an installation is healthy, run the per-target checks from the toolkit root:

```powershell
.\check_tool_armv7.ps1
.\check_tool_aarch64.ps1
.\check_tool_thumbv7em.ps1
.\check_tool_x64_win.ps1
```

## Using the toolkit in your own project

### Through the build scripts

Run the build script for your target from the project directory (the one containing `Cargo.toml`). The
script copies `config/.cargo/config.toml` into the project's `.cargo/` directory, sets the compiler and
linker variables for that target, and runs `cargo build --release`.

### With plain `cargo`

After activation, `cargo`, `rustc` and `rustup` on `PATH` are the toolkit's own, so ordinary commands
work:

```powershell
. D:\rust-portable-cross\scripts\rust_env.ps1
cargo build --release --target aarch64-unknown-linux-musl
cargo test
```

For the Linux targets, the project needs the linker settings from `config/.cargo/config.toml`; copy
that file into a `.cargo` directory in your project, or let a build script do it once.

### Crates with C or C++ code

Crates that compile C through [`cc`](https://crates.io/crates/cc) work for all targets. Activation sets
the per-target compiler and archiver variables (`CC_<target>`, `AR_<target>`, `RANLIB_<target>`) for
the two Linux targets, so their C code is built by Zig.

Cargo compiles build scripts and proc-macros for the *host* even when you cross-compile. The toolkit
links those host programs with its own Windows link inputs, so cross builds need no Visual Studio
either.

Host C code is the one place where the two ways of building differ:

| How you build for Windows | C compiler used | Needs Visual Studio |
|---|---|---|
| `rust_build_x64_win_native.ps1` | bundled Zig | No |
| plain `cargo` in an activated shell | whatever `cc` discovers on the machine | Yes, if a crate has C code |

### Bare-metal firmware

`thumbv7em-none-eabihf` is a `no_std` target, so a firmware project supplies its own linker script and
startup code. `sample_embedded` is a complete, dependency-free example to start from; see
[Sample projects](#sample-projects).

## Sample projects

| Directory | What it is |
|---|---|
| `sample/` | A `std` program using common crates (`tokio`, `reqwest` with rustls, `serde`, `clap`, …). Builds for the Windows, ARMv7 and ARM64 targets. Its dependencies ship with the offline installer, so it builds without network access. |
| `sample_embedded/` | Flashable `no_std` firmware for the HEM6801E board (GD32F427ZE, Cortex-M4F): its own `link.x`, vector table and a 1 Hz LED blink. |

Build a downloadable firmware image:

```powershell
. D:\rust-portable-cross\scripts\rust_env.ps1
D:\rust-portable-cross\sample_embedded\make_image.ps1
```

This builds the firmware and uses the bundled `rust-objcopy` to write `sample_embedded.bin` and
`sample_embedded.hex` for the active-app slot at `0x08008000`. Board wiring and flashing notes are in
`sample_embedded/README.md`.

## How it works

**Linux targets.** Rust's musl targets need a C linker and a libc. The toolkit supplies both through
Zig: small wrapper scripts in `tools/wrappers/` forward to `zig cc -target <zig-triple>`, and Zig builds
musl and the compiler runtime on first use and caches them. The wrappers also drop the arguments that
`cc` and `rustc` pass but Zig rejects.

**Windows target without Visual Studio.** Linking an `x86_64-pc-windows-msvc` program normally needs
Microsoft's import libraries and C runtime. The toolkit generates replacements from files that ship
with Zig, into `tools/sysroot/x86_64-pc-windows-msvc/lib/`:

- import libraries for the system DLLs, built from mingw-w64 module-definition files,
- `msvcrt.lib` as an import library for `ucrtbase.dll`, which is part of Windows 10 and later,
- `rpc_winshim.lib`, a small shim for the symbols no Windows DLL exports: the stack probe, the
  `printf` / `scanf` families, the program entry point and a few others.

Linking is done by the `rust-lld` that ships with Rust. No Microsoft-licensed file is redistributed.
The sysroot location is a stable contract: tools may test for it to decide whether an installation can
link Windows programs.

**Bare-metal target.** `thumbv7em-none-eabihf` links with `rust-lld` and uses no C toolchain at all.

**Isolation.** Activation sets `CARGO_HOME`, `RUSTUP_HOME` and the Zig cache directories to paths
inside the toolkit and puts the toolkit's programs first on `PATH`, for the current session only. Each
build script additionally clears compiler-related environment variables it does not own, so a build
does not pick up settings left by other tools.

**A smaller Zig.** Zig ships headers and libc sources for every platform it can target. Setup removes
those the toolkit never uses (macOS, glibc, WASI, other CPU architectures), about 40% of Zig's files.
Everything the supported targets can reach is kept, including the full C++ runtime.

## Scripts reference

### Setup and activation

| Script | Purpose |
|---|---|
| `scripts/rust_setup.ps1` | Downloads and installs the toolchain into `tools/`. Safe to repeat; `-Force` clears caches first. |
| `scripts/rust_env.ps1` | Activates the toolkit in the current session. Must be dot-sourced. |

`rust_env.ps1` exports `RUST_PORTABLE_CROSS_ROOT`, `CARGO_HOME`, `RUSTUP_HOME`, `RUSTUP_TOOLCHAIN`,
`ZIG_LOCAL_CACHE_DIR` and `ZIG_GLOBAL_CACHE_DIR`, sets `CC_*`, `AR_*` and `RANLIB_*` for the ARMv7 and
ARM64 targets, and updates `PATH`.

It never sets the unsuffixed `AR` or `RANLIB`: `cc` uses those for every target, including the Windows
host, where the GNU-style archiver would fail. If an older version left `AR=zig-ar.cmd` or
`RANLIB=zig-ranlib.cmd` behind, activation removes it; any other value is kept and a warning is shown.

### Build scripts

| Script | Target | Parameters |
|---|---|---|
| `scripts/rust_build_armv7.ps1` | `armv7-unknown-linux-musleabihf` | none; run from the project directory |
| `scripts/rust_build_aarch64.ps1` | `aarch64-unknown-linux-musl` | none; run from the project directory |
| `scripts/rust_build_thumbv7em.ps1` | `thumbv7em-none-eabihf` | none; run from the project directory |
| `scripts/rust_build_x64_win_native.ps1` | `x86_64-pc-windows-msvc` | `-ProjectPath` (default: the current directory), `-DebugBuild` |

### Checks

| Script | What it proves |
|---|---|
| `check_tool_armv7.ps1` | The bundled sample builds for ARMv7 Linux. |
| `check_tool_aarch64.ps1` | The bundled sample builds for ARM64 Linux. |
| `check_tool_thumbv7em.ps1` | The embedded sample builds, with the host Visual Studio environment removed. |
| `check_tool_x64_win.ps1` | A Windows build is self-contained: it builds with the host Visual Studio environment removed, runs the results, and fails if the linker used any file from outside the toolkit. |

### Maintenance and release

| Script | Purpose |
|---|---|
| `scripts/build_win_link_inputs.ps1` | Regenerates the Windows link inputs from the bundled Zig (`-Force` to rebuild them all). Needs no network and no Microsoft tooling. |
| `scripts/prepare_offline_release.ps1` | Assembles and verifies the installer payload under `dist/staging`. |
| `build.ps1` | Builds the offline installer. See [Building a release](#building-a-release). |
| `ci.ps1` | Runs the repository's checks. See [Development](#development). |

## Download configuration

`rust_setup.ps1` tries download sources in this order:

1. a direct URL (`RUST_PORTABLE_CROSS_RUSTUP_INIT_URL`, `RUST_PORTABLE_CROSS_ZIG_URL`),
2. a list of mirrors (`RUST_PORTABLE_CROSS_RUSTUP_MIRRORS`, `RUST_PORTABLE_CROSS_ZIG_MIRRORS`),
3. a mirror base URL (`RUST_PORTABLE_CROSS_RUSTUP_MIRROR_BASE`, `RUST_PORTABLE_CROSS_ZIG_MIRROR_BASE`),
4. a proxy prefix (`RUST_PORTABLE_CROSS_DOWNLOAD_PROXY_PREFIX`),
5. the official upstream.

Whatever the source, a download is accepted only if its SHA-256 digest matches the value recorded in
`scripts/dependency-lock.json`.

| Variable | Description |
|---|---|
| `RUST_PORTABLE_CROSS_RUSTUP_INIT_URL` | Direct URL for `rustup-init.exe` |
| `RUST_PORTABLE_CROSS_ZIG_URL` | Direct URL for the Zig archive |
| `RUST_PORTABLE_CROSS_RUSTUP_MIRRORS` | Mirror URLs for rustup, separated by `;`, `,` or newlines |
| `RUST_PORTABLE_CROSS_ZIG_MIRRORS` | Mirror URLs for Zig, separated by `;`, `,` or newlines |
| `RUST_PORTABLE_CROSS_RUSTUP_MIRROR_BASE` | Mirror base URL, joined with the built-in relative path |
| `RUST_PORTABLE_CROSS_ZIG_MIRROR_BASE` | Mirror base URL, joined with the built-in relative path |
| `RUST_PORTABLE_CROSS_DOWNLOAD_PROXY_PREFIX` | Prefix placed in front of the official upstream URL |
| `RUST_PORTABLE_CROSS_WGET_PATH` | Full path to a `wget` executable to use for downloads |
| `RUST_PORTABLE_CROSS_DOWNLOAD_RETRIES` | Retry count for the wget and curl backends (default 6) |
| `RUST_PORTABLE_CROSS_CURL_IP_MODE` | Force curl to IPv4 or IPv6: `4`, `6` or `auto` |

Unless you set them yourself, setup points `RUSTUP_DIST_SERVER` at `https://rsproxy.cn` and
`RUSTUP_UPDATE_ROOT` at `https://rsproxy.cn/rustup`, which is more reliable from mainland China.

## Building a release

`build.ps1` produces the offline installer. It needs a set-up toolkit (Option B above) and
[Inno Setup](https://jrsoftware.org/isdl.php) 6.

```powershell
git tag v1.6.0          # the version comes from the latest tag
.\build.ps1
```

| Parameter | Effect |
|---|---|
| `-Version` | Use the given `x.y.z` version instead of the latest git tag. |
| `-IsccPath` | Path to `ISCC.exe` when it is not in a standard location. |
| `-SkipStaging` | Reuse the existing staging instead of regenerating it. It is still verified. |
| `-ValidateInstall` | Also install the built EXE into a disposable directory and run the offline smoke builds against it. Adds several minutes. |

What a build does:

1. **Stage.** `prepare_offline_release.ps1` checks the toolchain, regenerates the Windows link inputs,
   runs the self-containment check, copies the payload to `dist/staging` and writes an integrity index
   with the SHA-256 digest of every file.
2. **Verify.** The staged version, pinned tools, file list and digests are checked.
3. **Compile.** Inno Setup compresses the payload into
   `dist/installer/rust-portable-cross-offline-<version>.exe`.
4. **Validate (only with `-ValidateInstall`).** The EXE is installed under `dist/v`, the complete
   sample is built offline for every target, the outputs are inspected, and the install is removed.
5. **Publish.** The EXE is copied to an `output` directory beside the repository, and split into 24 MB
   parts with a manifest for hosting behind size-limited downloads.

Run a build with `-ValidateInstall` before distributing a release whose payload changed.

A release payload is about 10,000 small files. If builds are slow, exclude `dist` from on-access
antivirus scanning; with Microsoft Defender, from an elevated PowerShell in the repository root:

```powershell
Add-MpPreference -ExclusionPath (Join-Path (Get-Location) 'dist')
```

## Development

### Tests

`ci.ps1` is the single verification entry point. It runs its checks concurrently, reports every failure
in one run, and exits non-zero if any check fails.

```powershell
.\ci.ps1          # default lane: one to two minutes, needs no installed toolchain
.\ci.ps1 -Full    # adds the four check_tool_*.ps1 builds and test/full/*.ps1; needs tools\
```

| Check | What it covers |
|---|---|
| `powershell-syntax` | Every tracked `.ps1` file parses. |
| `documentation-integrity` | Every toolkit path this README and the customer guide quote exists, and no tracked document contains stray control characters. |
| `test/*.tests.ps1` | Each test suite under `test\`, discovered rather than listed. |
| `openspec-validate` | `openspec validate --all --strict` over the specifications. |

A check whose prerequisite is missing reports `SKIP` with the reason. A skip is not a pass, and the
verdict says how many checks did not run. A suite reports a skip by printing `SKIP: <reason>` and
exiting with code 3.

Run one suite directly:

```powershell
pwsh -NoProfile -File .\test\rust_setup.tests.ps1
```

### Commit gate

```powershell
.\ci.ps1 -InstallHook
```

This points the clone's `core.hooksPath` at the version-controlled `.githooks\`, so `git commit` runs
the default lane and refuses the commit when it fails. It is a per-clone opt-in, installing again is a
no-op, and the installer refuses to overwrite a `core.hooksPath` it did not set.

| Bypass | Effect |
|---|---|
| `git commit --no-verify` | Skips the gate for one commit. |
| `$env:RUST_PORTABLE_CROSS_SKIP_CI = "1"` | Skips the gate for scripted commits. |
| `git config --unset core.hooksPath` | Uninstalls the gate from this clone. |

The gate checks the working tree, not the staged content, and warns when the two differ. It skips
itself during a merge or rebase. Every skip is stated on its own line and never reported as a pass.

### Specifications

Behaviour the project commits to is written down under `openspec/specs/`, one directory per
capability, and changes are proposed and archived under `openspec/changes/`. A change that alters
behaviour updates the matching specification in the same commit.

## Repository layout

```
rust-portable-cross/
├── build.ps1                     # Builds the offline installer
├── ci.ps1                        # Verification entry point and commit gate
├── check_tool_*.ps1              # Per-target health checks
├── .githooks/pre-commit          # Runs ci.ps1; installed with ci.ps1 -InstallHook
├── config/.cargo/config.toml     # Cargo linker settings for the Linux targets
├── docs/
│   └── customer/README-offline.md  # Guide shipped with the installer
├── openspec/                     # Specifications and change records
├── packaging/inno/               # Inno Setup installer script
├── sample/                       # std sample project
├── sample_embedded/              # no_std firmware sample (HEM6801E)
├── scripts/
│   ├── rust_setup.ps1            # One-time toolchain installation
│   ├── rust_env.ps1              # Activation (dot-source)
│   ├── rust_build_*.ps1          # Per-target build scripts
│   ├── build_win_link_inputs.ps1 # Generates the Windows link inputs
│   ├── prepare_offline_release.ps1  # Assembles the installer payload
│   ├── finalize_offline_install.ps1 # Runs at the end of installation
│   ├── dependency-lock.json      # Pinned versions and download digests
│   └── ...                       # Shared helpers
├── test/                         # Test suites run by ci.ps1
│   └── full/                     # Slow checks that need the toolchain
├── tools/                        # Installed toolchain (generated, not tracked)
│   ├── cargo-home/               # CARGO_HOME
│   ├── rustup-home/              # RUSTUP_HOME
│   ├── zig/                      # Zig compiler
│   ├── wrappers/                 # Zig compiler and archiver wrappers
│   ├── sysroot/                  # Generated Windows link inputs
│   └── downloads/                # Download cache
└── dist/                         # Build output (generated, not tracked)
```

## Troubleshooting

**A build script or `cargo` is "not recognized".**
The session is not activated. Dot-source `scripts/rust_env.ps1` from the toolkit directory, including
the leading dot and space. Running the script without the dot changes nothing in your session.

**"Missing Windows link inputs" or `could not open 'kernel32.lib'`.**
The generated link inputs are missing or incomplete. Regenerate them:

```powershell
.\scripts\build_win_link_inputs.ps1 -Force
```

**`ar: error: unknown option n` while building a crate with C code.**
An unsuffixed `AR` variable is pointing at a GNU-style archiver during a Windows host build. Activate
again with a current version of the toolkit, which removes the value older versions set. If you set
`AR` yourself, unset it or use `AR_<target>` instead.

**A C header such as `afx.h` or an ATL header is not found on the Windows target.**
The crate's C code needs Microsoft's own headers. The bundled compiler provides the mingw-w64 headers,
which cover the Windows API but not MFC, ATL or other Visual Studio libraries. That crate needs a real
MSVC installation.

**Undefined `wprintf`, `swprintf` or another wide-character formatted-I/O function at link time.**
The shim provides the narrow-character `printf` and `scanf` families only. Add the missing functions to
the symbol list in `scripts/build_win_link_inputs.ps1` and regenerate.

**The firmware build fails at link time for `thumbv7em-none-eabihf`.**
A bare-metal program needs a linker script that describes the chip's memory. Start from
`sample_embedded/link.x` and `sample_embedded/build.rs`.

**The first build for a target is slow.**
Zig compiles the C library and compiler runtime for that target on first use, then caches them under
`tools/zig-global-cache/`. Later builds reuse the cache.

**Builds or the installer are slow on a machine with antivirus software.**
On-access scanning of thousands of small files dominates. Excluding the toolkit directory, or `dist`
when building releases, removes most of the delay.

**The toolkit directory was moved.**
Activate from the new location. Paths are derived from where the scripts are, not stored.

## Known limitations

- Windows x86-64 is the only supported host.
- The Rust and Zig versions are pinned; changing them means updating `scripts/dependency-lock.json`
  and re-verifying the release.
- Linux targets are musl only. glibc targets are not supported.
- C code for the Windows target is compiled against mingw-w64 headers, so code that depends on
  Microsoft-only headers needs a host MSVC installation.
- `pthread.h` is not available for C code on the Windows target.
- Wide-character `printf` / `scanf` functions are not provided for C code on the Windows target.
- Plain `cargo` in an activated shell uses the machine's own C compiler for *host* C code; only
  `rust_build_x64_win_native.ps1` builds host C code without Visual Studio.

## Contributing

Issues and pull requests are welcome at
<https://gitee.com/yoursmengle/rust-portable-cross>.

Before sending a change:

1. Run `.\ci.ps1`, and `.\ci.ps1 -Full` if the change touches the toolchain, the build scripts or the
   payload.
2. Add or update a test under `test/` for any behaviour you change.
3. Update the matching specification under `openspec/specs/` when behaviour changes.
4. Update this README, `README.zh-CN.md` and `docs/customer/README-offline.md` when users would notice
   the change. The documentation check fails if this README or the customer guide names a path that
   does not exist.

Installing the commit gate (`.\ci.ps1 -InstallHook`) runs the default lane on every commit.

## License

rust-portable-cross is licensed under the GNU Affero General Public License, version 3. See
[`LICENSE`](LICENSE).

The toolkit downloads and redistributes third-party software under their own licenses, including
[Rust](https://www.rust-lang.org/) (MIT / Apache-2.0), [Zig](https://ziglang.org/) (MIT) with its
bundled musl, mingw-w64, LLVM libc++ and libunwind sources, and the crates used by the sample project.
The generated Windows link inputs record the source and license of every file in a `PROVENANCE.json`
beside them, and the installer ships a manifest of the sample's dependencies and their licenses.
