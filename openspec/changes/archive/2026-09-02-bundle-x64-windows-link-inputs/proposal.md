## Why

`rust-portable-cross` claims to be a self-contained portable Rust toolchain, but its
`x86_64-pc-windows-msvc` path is not: it ships a linker without the link *inputs*. On a machine
with no Visual Studio and no Windows SDK, `scripts/rust_build_x64_win_native.ps1` fails, and the
error text points users at the wrong fix (installing an MSVC linker) because the real gap is a
missing set of `.lib` files.

Measured on this repository (toolkit at `D:\hecas\rust-portable-cross-src`, Zig 0.13.0):

- `rustc --print link-args --target x86_64-pc-windows-msvc -C linker=rust-lld -C linker-flavor=lld-link`
  emits exactly `kernel32.lib ntdll.lib userenv.lib ws2_32.lib dbghelp.lib` and `/defaultlib:msvcrt`.
  No `/LIBPATH:` appears on the command line — `rustc` discovers the host Visual Studio / Windows SDK
  through its built-in registry probe and injects `LIB` into the linker child process.
- The linker itself is never the problem. `rust-lld.exe` is present at
  `tools/rustup-home/toolchains/stable-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/bin/`,
  `scripts/rust_env.ps1` already hard-requires it, and `rust_build_x64_win_native.ps1` already sets
  `CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER=rust-lld` with `-C linker-flavor=lld-link`. Builds link
  with `rust-lld` end to end; `link.exe` is never invoked.
- No `kernel32.lib` exists anywhere under `tools/`, and there is no
  `lib/rustlib/x86_64-pc-windows-msvc/lib/self-contained/` directory (the musl targets have one; the
  MSVC target does not).
- Builds succeed on this machine only because it has MSVC Build Tools 2022 at
  `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` plus Windows SDK 10.0.26100.0.
  That is the host dependency the product documentation denies: `docs/customer/README-offline.md:62`
  states the x64 build "uses only this installer's `tools/cargo-home` and `tools/rustup-home` toolchain."
- Excluding the CRT (`/NODEFAULTLIB:msvcrt`) reveals the complete residual symbol surface, and it is
  small and closed: `mainCRTStartup`, `__CxxFrameHandler3`, `_CxxThrowException`,
  ``const type_info::`vftable` ``, `__chkstk`, `_tls_index`, `_fltused`, `atexit`, `memcpy`, `memmove`,
  `memset`, `memcmp`, `strlen`.
- The bundled Zig can already produce every Windows import library offline. It ships mingw-w64
  module-definition files (772 in `lib/libc/mingw/lib-common/`, 481 in `lib64/`) and a `zig dlltool`
  subcommand. A single offline `zig cc -target x86_64-windows-gnu` invocation materialised
  `kernel32.lib`, `ntdll.lib`, `userenv.lib`, `ws2_32.lib`, `dbghelp.lib`, `advapi32.lib`, `ole32.lib`,
  `oleaut32.lib`, `shell32.lib`, `user32.lib`, the full `api-ms-win-crt-*` UCRT set, `mingw32.lib`,
  `c.lib`, `compiler_rt.lib` and `libunwind.a` into `tools/zig-global-cache`.

So the missing pieces are already derivable from assets we ship and are free to redistribute. The fix
belongs here rather than in a consumer repository: this toolchain is the artifact we distribute, the
desktop installer (`desktop/src/main/rust-toolkit-install.ts`) already has a split-volume download with
SHA-256 verification that can carry the extra payload to existing users, and `check_tool_x64_win.ps1`
would keep failing if the libraries were dropped into a consumer's tree instead.

## What Changes

- Add a generated, redistributable Windows link-input sysroot to the toolkit at
  `tools/sysroot/x86_64-pc-windows-msvc/lib/`, containing the import libraries the MSVC target links
  against plus a small static shim archive covering the CRT startup and EH symbols listed above.
- Add `scripts/build_win_link_inputs.ps1`, which regenerates that sysroot **offline** from the bundled
  Zig (`zig dlltool` over the bundled mingw-w64 `.def` files, `zig cc` for the shim). The sysroot is a
  build-time-generated, checked-in-to-the-release artifact, not a hand-collected pile of binaries.
- Make `scripts/rust_build_x64_win_native.ps1` pin `LIB` to the bundled sysroot and pass
  `-C link-self-contained` / explicit `/LIBPATH:` so the link never consults host Visual Studio or
  Windows SDK paths, even when they exist.
- Replace the misleading "install the MSVC linker" diagnostics with an accurate message naming the
  missing link inputs and the script that regenerates them.
- Extend `check_tool_x64_win.ps1` into a real self-containment check: build the sample with host MSVC
  and SDK environment variables scrubbed and host discovery suppressed, then assert the produced
  executable runs and that no linker input resolved outside the toolkit root.
- Promote `x64_win` to a first-class entry in `install-layout.json`: `scripts/prepare_offline_release.ps1`
  ships the new sysroot in the `core` component so the offline installer and the desktop installer
  channel deliver it.
- Correct `docs/customer/README-offline.md` and `README.md`, which currently assert host independence
  that does not hold.
- **BREAKING** for release packaging: the offline package gains a new required payload directory;
  installers built before this change produce a toolkit that still depends on host MSVC.

## Capabilities

### New Capabilities

- `x64-windows-link-inputs`: the toolkit supplies, regenerates and uses its own Windows import
  libraries and CRT shim for `x86_64-pc-windows-msvc`, so linking never depends on a host Visual
  Studio or Windows SDK installation.
- `toolchain-self-containment-check`: a verifiable guarantee, enforced by a check script, that an
  `x86_64-pc-windows-msvc` build consumes no file outside the toolkit root.

### Modified Capabilities

None. `openspec/specs/` is currently empty, so both capabilities above are new.

## Impact

- **Scripts**: `scripts/rust_build_x64_win_native.ps1`, `scripts/rust_env.ps1`,
  `scripts/prepare_offline_release.ps1`, `scripts/finalize_offline_install.ps1`,
  `check_tool_x64_win.ps1`; new `scripts/build_win_link_inputs.ps1`.
- **Toolkit payload**: new `tools/sysroot/x86_64-pc-windows-msvc/` tree, generated rather than
  committed (added to `tools/.gitignore`), so generation is part of the release pipeline.
- **Packaging**: `install-layout.json` `core` component file list grows; offline package size grows by
  the import-library set (small — import libs are stubs, not code).
- **Docs**: `docs/customer/README-offline.md`, `README.md`.
- **Downstream**: `desktop/src/main/rust-toolkit-install.ts` ships a larger toolkit archive and must
  have its expected SHA-256 / volume manifest regenerated. `hec-core`'s `runtime/` tree is explicitly
  *not* touched.
- **Licensing**: everything shipped derives from mingw-w64 definition files already bundled inside Zig
  and from Zig's own compiler-rt, both redistributable. No Microsoft CRT or SDK binary is redistributed.
