# Rust Portable Cross Offline Installer

## What This Installer Provides

This installer deploys a prebuilt offline Rust toolchain for Windows.

- The installer itself does not download anything.
- The sample Rust project is installed under `sample\`.
- You can choose support for:
  - `armv7`
  - `aarch64`
  - `thumbv7em` (ARM Cortex-M4F/M7 bare-metal, `thumbv7em-none-eabihf`)
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
- `.\scripts\rust_build_thumbv7em.ps1`
- `.\scripts\rust_build_x64_win_native.ps1 -ProjectPath <your-project-path>`

If a target was not selected during installation, its build script or wrapper files may be absent.

### Notes for `thumbv7em-none-eabihf`

- This is a bare-metal (`no_std`) ARM Cortex-M4F/M7 target. It links with the
  bundled `rust-lld`, so it needs no Zig wrapper or external C cross-toolchain.
- Building a firmware binary requires a linker script. The bundled
  `sample_embedded` crate is a complete example for the HEM6801E board
  (GD32F427ZE) that ships its own `link.x`, so you can use it as a starting
  point for your own firmware.
- To produce a downloadable image, run `sample_embedded\make_image.ps1` after
  activating the environment. It builds the firmware and uses the bundled
  `rust-objcopy` to emit `sample_embedded.bin` and `sample_embedded.hex` for the
  active-app slot at `0x08008000`. See `sample_embedded\README.md` for wiring and
  flashing details.

## Notes

- Windows host support uses `x86_64-pc-windows-msvc`.
- This toolkit only provides Linux cross-target wrappers.
- For `x86_64-pc-windows-msvc`, prefer `rust_build_x64_win_native.ps1`. It needs **no Visual Studio,
  no MSVC linker (`link.exe`) and no Windows SDK**: linking uses the bundled `rust-lld` together with
  the Windows import libraries this installer ships under
  `tools\sysroot_64-pc-windows-msvc\lib`. Those libraries take precedence even on a machine
  that does have Visual Studio installed, so builds are identical everywhere.
- Executables built for `x86_64-pc-windows-msvc` run on **Windows 10 / Windows Server 2016 and later**.
  They use the operating system's own C runtime (`ucrtbase.dll`) and need no Visual C++ redistributable
  installed alongside them.
- To verify that a build used nothing from outside this installation, run `check_tool_x64_win.ps1`. It
  builds with the host Visual Studio environment scrubbed and fails if any library resolved from
  outside the installation directory.
- If the link inputs are ever missing, regenerate them offline with `scriptsuild_win_link_inputs.ps1`.
  They are derived from the bundled Zig installation, so this needs no network access.
- One limitation: a crate whose C code genuinely requires Microsoft's own headers (rather than the
  bundled mingw-w64 headers) still needs a host MSVC installation. This shows up as a compile error
  from the C build script naming a missing Microsoft header, not as a link error.
- This installer does not make arbitrary third-party crate downloads offline. If your project depends on crates that are not already available in your environment, dependency fetching remains your responsibility.
