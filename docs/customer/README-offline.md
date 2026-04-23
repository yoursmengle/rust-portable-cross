# Rust Portable Cross Offline Installer

## What This Installer Provides

This installer deploys a prebuilt offline Rust toolchain for Windows.

- The installer itself does not download anything.
- You can choose support for:
  - `armv7`
  - `aarch64`
  - `x64_win`
- `armv7` is selected by default.
- Only the selected target payloads are installed.

## Installation Scope

The installer supports:

- current-user installation
- all-users installation

Current-user installation is the default.

## First Use

After installation, run:

- `Activate Rust Portable Cross (PowerShell)`

This loads the environment variables required by the toolkit in the current PowerShell session.

## Target Build Scripts

Run the build scripts from inside your Rust project directory:

- `.\scripts\rust_build_armv7.ps1`
- `.\scripts\rust_build_aarch64.ps1`
- `.\scripts\rust_build_x64_win.ps1`

If a target was not selected during installation, its build script or wrapper files may be absent.

## Notes

- Windows host support uses `x86_64-pc-windows-gnu`.
- Linux cross-target support uses Zig-based wrapper scripts.
- This installer does not make arbitrary third-party crate downloads offline. If your project depends on crates that are not already available in your environment, dependency fetching remains your responsibility.
