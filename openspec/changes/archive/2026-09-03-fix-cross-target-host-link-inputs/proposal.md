## Why

Cross-target builds still compile host artifacts (`build.rs`, proc-macros) as
`x86_64-pc-windows-msvc` binaries. The Windows native path already feeds those
links the bundled sysroot; the `thumbv7em`, `armv7`, and `aarch64` build scripts
only force `rust-lld` and do not. On a machine with Visual Studio this is
invisible because `rustc` injects the host SDK `LIB` path from its registry
probe. On a machine without Visual Studio or the Windows SDK the host link
fails with `rust-lld: error: could not open 'kernel32.lib'`, which is the
failure a customer hit after installing this toolkit and running
`check_tool_thumbv7em.ps1`.

## What Changes

- Apply the same bundled Windows link inputs already used by
  `rust_build_x64_win_native.ps1` (`/LIBPATH:` to
  `tools/sysroot/x86_64-pc-windows-msvc/lib` plus `rpc_winshim.lib`) to every
  toolkit cargo invocation that links a host `x86_64-pc-windows-msvc` artifact,
  including `rust_build_thumbv7em.ps1`, `rust_build_armv7.ps1`, and
  `rust_build_aarch64.ps1`.
- Fail before `cargo` when those inputs are missing, with the same diagnostic
  the Windows native path already uses (name the sysroot path and
  `build_win_link_inputs.ps1`; do not tell the user to install Visual Studio).
- Correct `rust_env.ps1`, which currently warns that "cross targets do not need"
  the sysroot — they do, because cargo still links host build scripts.
- Extend the env-script tests so the three cross-target builders are asserted
  to pin `/LIBPATH:` and `rpc_winshim.lib` the same way the x64 builder already
  is.
- Document that a `thumbv7em` (and other cross-target) build on a bare Windows
  machine uses the bundled Windows link inputs for host artifacts, not a host
  Visual Studio install.

## Capabilities

### New Capabilities

None. The sysroot, generator, and Windows native path already exist.

### Modified Capabilities

- `x64-windows-link-inputs`: the exclusive-use and missing-sysroot requirements
  currently apply only when the cargo `--target` is `x86_64-pc-windows-msvc`.
  They SHALL also apply whenever a toolkit build script links a host
  `x86_64-pc-windows-msvc` artifact during a cross-target build.
- `toolchain-self-containment-check`: the self-containment guarantee currently
  covers only `check_tool_x64_win.ps1`. The bundled `thumbv7em` check (and the
  other cross-target checks that compile host build scripts) SHALL also succeed
  with host MSVC / Windows SDK environment variables scrubbed.

## Impact

- **Scripts**: `scripts/rust_build_thumbv7em.ps1`, `scripts/rust_build_armv7.ps1`,
  `scripts/rust_build_aarch64.ps1`, `scripts/rust_build_x64_win_native.ps1`,
  `scripts/rust_build_isolation.ps1`, `scripts/rust_env.ps1`.
- **Checks**: `check_tool_thumbv7em.ps1` starts working on a machine without
  Visual Studio once the build script pins the sysroot; the other
  `check_tool_*.ps1` wrappers inherit the same host-link behaviour.
- **Tests**: `test/rust_build_env.tests.ps1` grows assertions for host
  `/LIBPATH:` / `rpc_winshim.lib` on the three cross-target scripts.
- **Docs**: `docs/customer/README-offline.md`, `README.md` — the "no Visual
  Studio" claim currently sits only under the x64 native notes.
- **Payload / packaging**: none. The sysroot is already in the always-installed
  `core` component from `bundle-x64-windows-link-inputs`.
- **Not in scope**: changing the `thumbv7em` target linker, linker script, or
  `sample_embedded` firmware; shipping MSVC headers; making ad-hoc
  `cargo build --target ...` after `rust_env.ps1` (without a toolkit build
  script) self-contained.
