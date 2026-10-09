## Why

`scripts/rust_env.ps1` (loaded by `Activate Rust Portable Cross.ps1`) sets the unsuffixed `AR=zig-ar.cmd` and `RANLIB=zig-ranlib.cmd`. cc-rs uses those as the fallback archiver for every target, including the host `x86_64-pc-windows-msvc`, where it calls the archiver in `lib.exe` form (`-out:<path> -nologo`). `zig ar` is GNU-style and rejects that (`ar: error: unknown option n`), so after activation any host crate with C sources fails to build. This was observed on 2026-10-09 with `bzip2-sys` in the HEC workspace. The bundled `ring` dependency of `sample` hits the same path. The toolkit's own build scripts call `Clear-RustBuildEnvironment` first, so they hide the defect. Only users who run `cargo` directly in an activated shell see it.

## What Changes

- Activation sets archiver variables only in target-scoped form (`AR_<triple>` / `RANLIB_<triple>`, in both underscore and hyphen spellings) for `armv7-unknown-linux-musleabihf` and `aarch64-unknown-linux-musl`. It no longer sets the unsuffixed `AR` or `RANLIB`.
- On activation, an unsuffixed `AR` / `RANLIB` whose value is exactly the toolkit's own `zig-ar.cmd` / `zig-ranlib.cmd` is removed. This clears leftovers from an earlier activation by this or an older toolkit version. Any other value is treated as user-owned: it is kept, and a warning is emitted.
- Add regression tests for the scoped variables, leftover cleanup, preservation of user-set values, and a host `cargo build` of a crate that uses cc-rs in an activated shell.
- Non-goal: making host C builds in the activated shell independent of Visual Studio. This change does not set `AR_x86_64_pc_windows_msvc` / `CC_x86_64_pc_windows_msvc`; see design.md.

## Capabilities

### New Capabilities

- `activation-archiver-scope`: The interactive activation environment scopes the bundled GNU-style archivers to the cross targets that need them. It never redirects the host target's archiver, and it reconciles leftover unsuffixed `AR` / `RANLIB` values on re-activation.

### Modified Capabilities

(none)

## Impact

- `scripts/rust_env.ps1`: archiver variable block and leftover reconciliation.
- `test/`: new activation-environment tests. The host cc-rs end-to-end case uses `sample`'s existing offline-locked `ring` → `cc` dependency, so the offline dependency set does not change.
- No change to `rust_build_*.ps1`, `rust_build_isolation.ps1`, wrappers, or release payload contents. The `check_tool_*.ps1` scripts must keep passing.
