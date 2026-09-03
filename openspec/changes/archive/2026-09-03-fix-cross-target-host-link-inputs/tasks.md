## 1. Shared host-link helper

- [x] 1.1 In `scripts/rust_build_isolation.ps1`, add `Initialize-WindowsHostLinkInputs -ToolkitRoot` that resolves `tools\sysroot\x86_64-pc-windows-msvc\lib`, requires `kernel32.lib`, `ntdll.lib`, `userenv.lib`, `ws2_32.lib`, `dbghelp.lib`, `msvcrt.lib`, and `rpc_winshim.lib`, and throws the existing x64 here-string (sysroot path, missing names, `.\scripts\build_win_link_inputs.ps1`, "not a missing linker") when any file is absent
- [x] 1.2 Have the helper set `CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER=rust-lld` and append, via `Add-RustBuildFlagIfMissing`, `-C linker-flavor=lld-link`, `-C link-arg=/LIBPATH:$winSysrootLib`, and `-C link-arg=rpc_winshim.lib`
- [x] 1.3 Confirm the helper does not set `+crt-static` and does not mention Visual Studio, `link.exe`, or the Windows SDK in its missing-sysroot diagnostic

## 2. Build scripts

- [x] 2.1 Call `Initialize-WindowsHostLinkInputs -ToolkitRoot $toolkitRoot` from `scripts/rust_build_thumbv7em.ps1` after `Clear-RustBuildEnvironment` / `Repair-CargoHostTargetConfig` and before `cargo build`; remove the script-local `$hostRustflags` assignment so the helper is the only source of host linker flags
- [x] 2.2 Do the same in `scripts/rust_build_armv7.ps1` and `scripts/rust_build_aarch64.ps1`, leaving their musl Zig/CC/AR/RANLIB wiring unchanged
- [x] 2.3 Refactor `scripts/rust_build_x64_win_native.ps1` onto the helper: drop the private required-library list, `Test-WindowsLinkInputs`, early missing-sysroot throw, and the `/LIBPATH:` / `rpc_winshim.lib` flag appends; keep the Zig `windows-gnu` C wrapper, `HOST_CC` / `CC` / `AR` / `RANLIB` wiring, and the `+crt-static` prohibition comment
- [x] 2.4 In `scripts/rust_env.ps1`, keep the missing-sysroot path as a warning (not a throw) and rewrite the comment and warning text so they state that every toolkit cargo build that links a host artifact needs the sysroot, including `thumbv7em` / `armv7` / `aarch64`

## 3. Tests

- [x] 3.1 In `test/rust_build_env.tests.ps1`, assert the isolation helper defines `Initialize-WindowsHostLinkInputs`, contains `/LIBPATH:`, `rpc_winshim.lib`, and `build_win_link_inputs.ps1`, and does not request `+crt-static`
- [x] 3.2 Assert each of `rust_build_thumbv7em.ps1`, `rust_build_armv7.ps1`, `rust_build_aarch64.ps1`, and `rust_build_x64_win_native.ps1` calls `Initialize-WindowsHostLinkInputs` after `Clear-RustBuildEnvironment` and before `cargo build`
- [x] 3.3 Update `Assert-X64WinEnvBeforeCargoBuild` so it no longer greps the x64 script body for `/LIBPATH:` / `rpc_winshim.lib` / the private `Test-WindowsLinkInputs` throw; keep its project-path, isolation, Zig C-wrapper, and `+crt-static` assertions
- [x] 3.4 Keep the existing per-target linker / Zig-wrapper / "no thumbv7em linker override" assertions on the musl and thumbv7em scripts
- [x] 3.5 Run `.\test\rust_build_env.tests.ps1` and confirm it passes

## 4. Documentation

- [x] 4.1 In `docs/customer/README-offline.md`, under the `thumbv7em-none-eabihf` notes, state that cargo still links host build scripts as `x86_64-pc-windows-msvc` binaries and that those host links use the bundled Windows link inputs under `tools\sysroot\x86_64-pc-windows-msvc\lib`, so no Visual Studio or Windows SDK is required
- [x] 4.2 Apply the same host-link note to the `README.md` section that describes `rust_build_thumbv7em.ps1` / `rust_build_armv7.ps1` / `rust_build_aarch64.ps1`

## 5. End-to-end verification

- [x] 5.1 With host `LIB` / `INCLUDE` / `VCINSTALLDIR` / `WindowsSdkDir` cleared, run `.\check_tool_thumbv7em.ps1` and confirm `sample_embedded` builds for `thumbv7em-none-eabihf` (the host `build.rs` must link without the host SDK)
- [x] 5.2 Temporarily rename `tools\sysroot\x86_64-pc-windows-msvc\lib`, run `.\check_tool_thumbv7em.ps1`, and confirm it fails before `cargo` naming the missing inputs and `build_win_link_inputs.ps1` without blaming the linker; restore the directory
- [x] 5.3 Run `.\check_tool_x64_win.ps1` to confirm the x64 native path still passes after the helper extract
- [x] 5.4 Run `.\ci.ps1` (default lane) and confirm the PowerShell parse check and `test/*.tests.ps1` suites pass
