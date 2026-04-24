# x64 Windows Portable Target And Default Install Design

## Goal

Make the `x64_win` target behave like the Linux targets from the customer's point of view: it is portable, target-scoped, installable by default, and removable by the installer component selection UI without damaging the shared Rust toolchain.

## Context

The repository already installs Rust, Cargo, rustup, Zig, wrappers, and target-specific build scripts into a repository-local `tools/` layout. The offline installer currently stages a shared `core` payload plus target payloads under `dist/staging/targets/<component>`.

The existing component model is close, but it has two gaps:

- `x64_win` is optional but not selected by the default installer type.
- `rust_build_x64_win.ps1` currently performs a plain host build and removes `.cargo/config.toml`, so it does not force the Windows GNU build through the portable wrapper layer.

The component boundary must not move `rustc`, `cargo`, host `rust-std`, or the Rust-provided MinGW self-contained files out of `core`. Those files are part of the GNU host toolchain and may be needed by Rust itself, build scripts, proc macros, or other targets. The optional `x64_win` component should only own the target exposure layer.

## Requirements

- The installer default type installs all target components: `armv7`, `aarch64`, and `x64_win`.
- The custom installer path still lets the user deselect any one or more target components.
- Deselecting `x64_win` removes only its target-owned files.
- The shared GNU host toolchain remains in `core` regardless of target selection.
- The Windows x64 build script explicitly builds `x86_64-pc-windows-gnu` through portable configuration.
- Tests cover the default component metadata and component-owned file behavior.
- Customer docs describe that all targets are selected by default.

## Recommended Architecture

Keep `core` as the always-installed base:

- `scripts/rust_env.ps1`
- `scripts/finalize_offline_install.ps1`
- Cargo/rustup proxy binaries under `tools/cargo-home/bin`
- Rust GNU host toolchain under `tools/rustup-home/toolchains/stable-x86_64-pc-windows-gnu`, except generated component metadata and non-default cross-target rustlib directories
- Zig under `tools/zig`
- shared config and docs

Keep target components as thin overlays:

- `armv7`: build script, Zig wrapper, `armv7-unknown-linux-musleabihf` rust-std payload and manifest
- `aarch64`: build script, Zig wrapper, `aarch64-unknown-linux-musl` rust-std payload and manifest
- `x64_win`: build script plus `x86_64-w64-mingw32-gcc` wrapper files, and any target-specific Cargo config needed to expose the portable linker

This avoids the unsafe alternative of making host Rust files optional while still giving users a meaningful way to hide the x64 Windows build flow.

## Portable x64 Build Flow

`rust_build_x64_win.ps1` should mirror the target-specific behavior of the Linux scripts:

1. Require the toolkit environment to be active.
2. Require `Cargo.toml` in the current project directory.
3. Copy toolkit-owned Cargo target configuration into the project `.cargo/config.toml`.
4. Run `cargo build --release --target x86_64-pc-windows-gnu`.
5. Report `target\x86_64-pc-windows-gnu\release` as the output directory.

The target config must include a section for `x86_64-pc-windows-gnu` pointing at `x86_64-w64-mingw32-gcc.cmd`. This makes the build path independent of system MinGW or MSVC linker discovery.

## Installer Behavior

The Inno Setup component table should keep `core` fixed and make all three targets part of the default type:

- `core`: fixed, default, custom
- `armv7`: default, custom
- `aarch64`: default, custom
- `x64_win`: default, custom

The selected component callback should continue passing the actual selected target list to `finalize_offline_install.ps1`. The finalize script should continue removing files for deselected components based on `install-layout.json` ownership data.

## Metadata Behavior

`scripts/prepare_offline_release.ps1` should set:

```powershell
$script:DefaultComponents = @("armv7", "aarch64", "x64_win")
```

`install-layout.json` should therefore record all three targets as defaults. This metadata is useful for tests and future installer automation, even though Inno owns the interactive default selection UI.

## Tests

Update the existing PowerShell tests rather than introducing a new test harness:

- `test/prepare_offline_release.tests.ps1` should assert that `defaultComponents` contains exactly `armv7`, `aarch64`, and `x64_win`.
- The prepare test should assert that the `x64_win` staged payload records its build script and wrapper files.
- `test/finalize_offline_install.tests.ps1` should keep coverage for deselecting `aarch64` while preserving selected `armv7` and `x64_win`.
- Add or adjust assertions to make clear that deselected target files are removed and selected target files remain.

If the x64 Cargo config is represented as a separate file, tests should cover its staging ownership under `x64_win`.

## Documentation

Update customer-facing docs to state:

- all targets are selected by default
- users may deselect one or more targets in custom installation
- `x64_win` uses `x86_64-pc-windows-gnu`
- target build scripts may be absent if the corresponding component was deselected

## Risks And Mitigations

Risk: Treating Rust-provided MinGW files as optional could break unrelated builds.

Mitigation: Keep the full GNU host toolchain in `core`; only make wrapper and build-entry files optional.

Risk: Copying a single shared `.cargo/config.toml` into projects could expose wrappers for deselected components.

Mitigation: Either keep only installed wrappers referenced by installed build scripts, or split target Cargo config into target-specific snippets. Prefer the smallest change that ensures `rust_build_x64_win.ps1` always configures `x86_64-pc-windows-gnu` correctly.

Risk: Existing project `.cargo/config.toml` is overwritten by build scripts.

Mitigation: Preserve existing project behavior for this change. The current Linux build scripts already copy toolkit config into the project, so improving config merge behavior is out of scope.

## Acceptance Criteria

- Running the offline release staging test shows all three default components in layout metadata.
- Running finalize tests shows deselected component files are removed without deleting selected or core files.
- The installer component list defaults to all target components selected.
- `rust_build_x64_win.ps1` uses `--target x86_64-pc-windows-gnu` and the portable wrapper config.
- Customer docs no longer say only `armv7` is selected by default.
