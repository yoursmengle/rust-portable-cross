# Offline Inno Installer Design

Date: 2026-04-23

## Summary

Build a single offline Inno Setup installer for `rust-portable-cross` that:

- installs with no network access
- lets the customer choose support for `armv7`, `aarch64`, and `x64_win`
- selects `armv7` by default
- installs only the files required by the selected targets
- supports rerunning the same installer to modify installed components later
- supports both per-user and per-machine installation, defaulting to per-user

The installer will package prebuilt offline content generated on an internal connected machine. It must not run the existing online bootstrap flow on the customer machine.

## Current Project Context

The repository currently works as a portable Rust cross-compilation toolkit for Windows:

- `scripts/rust_setup.ps1` downloads and initializes toolchain content into `tools/`
- `scripts/rust_env.ps1` activates the local toolkit environment
- `scripts/rust_build_armv7.ps1`, `scripts/rust_build_aarch64.ps1`, and `scripts/rust_build_x64_win.ps1` build projects for the supported targets
- `config/.cargo/config.toml` holds the linker configuration for Linux musl targets

The current repository is suitable for internal setup, but not for direct customer installation, because `rust_setup.ps1` includes download behavior and the repository layout is not yet staged as installer components.

## Confirmed Decisions

- Distribution format: one `setup.exe`
- Installation behavior: install only selected target files
- Offline scope: installer must be fully offline; later customer project dependency downloads are out of scope
- Maintenance: rerunning the same installer must support adding or removing targets
- Install scope: support both per-user and per-machine installs, default to per-user
- Customer-facing layout: preserve script compatibility, but present a cleaner customer-oriented install root

## Goals

- Generate a single offline Windows installer for customer delivery
- Keep the existing script-based usage model intact after installation
- Split installed payload by target so disk usage reflects the user's selection
- Keep shared files installed once and reusable across all targets
- Make modify/repair/remove behavior deterministic

## Non-Goals

- Making customer builds fully offline for arbitrary third-party Rust dependencies
- Replacing the current script-driven build flow with a GUI product
- Supporting online self-update behavior inside the installer
- Using `rust_setup.ps1` as a post-install entrypoint on customer machines

## Architecture

The release flow is split into two stages.

### Stage A: Offline Release Preparation

An internal connected machine prepares a clean staging directory from the working repository and an already initialized `tools/` tree.

New script:

- `scripts/prepare_offline_release.ps1`

Responsibilities:

- validate that required offline toolchain files already exist
- create `dist/staging/`
- copy shared content into `dist/staging/core/`
- copy target-specific content into:
  - `dist/staging/targets/armv7/`
  - `dist/staging/targets/aarch64/`
  - `dist/staging/targets/x64_win/`
- generate component file manifests
- generate install metadata consumed by the installer
- produce a clean customer README for the install root

### Stage B: Installer Packaging

Inno Setup consumes `dist/staging/` and produces one customer-facing `setup.exe`.

New installer source:

- `packaging/inno/rust_portable_cross.iss`

Responsibilities:

- define required core payload
- define optional target components
- default to `armv7` selected
- support per-user and per-machine installation
- support maintenance mode on reinstall
- run local post-install validation only

## Component Model

The installer is based on four logical components:

- `core` (mandatory)
- `armv7` (optional, selected by default)
- `aarch64` (optional)
- `x64_win` (optional)

`core` contains only files required regardless of target choice. Target components contain only incremental files required to enable that target.

## Staging Layout

The prepared staging tree is:

```text
dist/
  staging/
    core/
      config/
      docs/
      scripts/
      tools/
      Activate Rust Portable Cross.ps1
      install-manifest.json
    targets/
      armv7/
      aarch64/
      x64_win/
```

The installed customer layout remains script-compatible:

```text
RustPortableCross/
  config/
  docs/
  scripts/
  tools/
  Activate Rust Portable Cross.ps1
  install-manifest.json
```

## File Partitioning Rules

### Core Files

Install these regardless of target selection:

- `scripts/`
- `config/`
- customer documentation under `docs/`
- `Activate Rust Portable Cross.ps1`
- `tools/rustup/`
- `tools/cargo-home/bin/` required executables and support binaries
- `tools/rustup-home/` host toolchain content shared by all supported flows
- `tools/zig/`
- shared wrapper infrastructure
- empty or minimal cache directory skeletons needed by `rust_env.ps1`

### armv7 Component

Install only when `armv7` is selected:

- `armv7-unknown-linux-musleabihf` standard library and target-specific rustup content
- `tools/wrappers/arm-linux-musleabihf-gcc.cmd`
- any armv7-only metadata markers

### aarch64 Component

Install only when `aarch64` is selected:

- `aarch64-unknown-linux-musl` standard library and target-specific rustup content
- `tools/wrappers/aarch64-linux-musl-gcc.cmd`
- any aarch64-only metadata markers

### x64_win Component

Install only when `x64_win` is selected:

- the wrapper files needed specifically for the Windows GNU target surface
- `tools/wrappers/x86_64-w64-mingw32-gcc.cmd`
- `tools/wrappers/x86_64-w64-mingw32-gcc.ps1`
- any x64_win-only metadata markers

### Important Constraint

`x64_win` is not a normal cross target from the installer's perspective because the host toolchain itself is `x86_64-pc-windows-gnu`. The partitioning logic must therefore distinguish:

- host files that are always required and belong in `core`
- wrapper or exposure files that are only needed when the customer wants the `x64_win` build flow

This distinction must be explicit in the staging rules and may not be inferred later from install directory contents.

## Install Metadata

Generate an `install-manifest.json` in the install root with:

- product name
- product version
- install scope
- installed components
- per-component owned file list
- shared file list

Purpose:

- support reliable modify operations
- support reliable uninstall of deselected components
- avoid deleting shared files still required by other components
- provide a deterministic basis for validation and future support diagnostics

The installer must use generated ownership data rather than guessing component ownership from directory names.

## Installer UX

### Install Scope

- default: per-user install
- optional: per-machine install
- installer requests elevation only when per-machine install is selected

### Component Selection

- `core` is always installed
- `armv7` is selected by default
- `aarch64` and `x64_win` are unselected by default

### Maintenance Mode

Rerunning the same `setup.exe` must support:

- `Modify`
- `Repair`
- `Remove`

Modify must allow adding or removing optional targets without requiring full uninstall.

### Shortcuts

Create Start Menu entries for:

- `Activate Rust Portable Cross (PowerShell)`
- `README`
- `Uninstall Rust Portable Cross`

Desktop shortcuts are not created by default.

## Post-Install Behavior

The installer must not call `scripts/rust_setup.ps1` on the customer machine.

Allowed post-install actions:

- write or update `install-manifest.json`
- create empty local cache directories if missing
- create shortcuts
- run local read-only validation commands

Disallowed post-install actions:

- downloading any content
- calling online package managers
- invoking any setup path that may attempt network access

## Validation

Run only local validation after install:

- verify presence of `cargo.exe`, `rustc.exe`, `rustup.exe`, `zig.exe`
- verify presence of wrappers for selected components
- run:
  - `cargo -V`
  - `rustc -V`
  - `rustup target list --installed`
- confirm selected target triples appear when expected

Validation failures must report a concrete local packaging error, such as missing target files or a corrupt payload.

## Release Artifacts

Add or reserve the following paths:

- `scripts/prepare_offline_release.ps1`
- `packaging/inno/rust_portable_cross.iss`
- `docs/customer/README-offline.md`
- `dist/` for generated artifacts only

`dist/` should not be committed.

## Tests

### Script-Level Tests

Add tests for:

- staging file partitioning
- manifest generation
- stable component ownership output

### Install Structure Tests

Verify installed file sets for at least:

- `core + armv7`
- `core + armv7 + aarch64`
- `core + armv7 + aarch64 + x64_win`

Each case must confirm that only expected target-specific files are present.

### Offline Functional Tests

In a disconnected environment:

- install the package
- activate the environment
- run `cargo -V`
- run `rustc -V`
- run `rustup target list --installed`
- build the sample project using the selected target scripts

This validates that installation and base toolchain usage are fully offline.

## Documentation Alignment

Update project documentation to match actual behavior:

- document Windows support as `x86_64-pc-windows-gnu`
- stop describing `rust_setup.ps1` as the customer installation path
- add customer-facing offline usage documentation separate from internal setup instructions

## Implementation Boundaries

The implementation should stay focused on:

- offline release preparation
- installer definition
- installer validation
- customer documentation
- tests for the new packaging path

Do not refactor unrelated repository areas as part of this work.
