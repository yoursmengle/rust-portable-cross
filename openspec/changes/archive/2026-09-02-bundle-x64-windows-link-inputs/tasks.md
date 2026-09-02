## 1. Sysroot generator

- [x] 1.1 Create `scripts/build_win_link_inputs.ps1` with parameters `-ToolkitRoot`, `-Arch` (default
      `x86_64`) and `-Force`; resolve the bundled Zig at `tools/zig/zig.exe` and fail with an
      actionable message if it is absent.
- [x] 1.2 Add the explicit import-library list (`kernel32`, `ntdll`, `userenv`, `ws2_32`, `dbghelp`,
      `advapi32`, `user32`, `ole32`, `oleaut32`, `shell32`, `bcrypt`) as a single named table so the
      set is auditable and extending it is a one-line change.
- [x] 1.3 Implement definition-file resolution: prefer `tools/zig/lib/libc/mingw/lib64/<name>.def`,
      fall back to `lib-common/<name>.def`, and preprocess `lib-common/<name>.def.in` with
      `zig cc -E` (defining the 64-bit architecture macros mingw expects) when only the `.in` form
      exists.
- [x] 1.4 Generate one import library per entry with `zig dlltool` into
      `tools/sysroot/x86_64-pc-windows-msvc/lib/`, and fail the script if any expected output is
      missing or zero-length.
- [x] 1.5 Generate `msvcrt.lib` as an import library for `ucrtbase.dll` from
      `tools/zig/lib/libc/mingw/lib-common/ucrtbase.def.in`, and assert that the result exports
      `__CxxFrameHandler3`, `_CxxThrowException`, `_crt_atexit`, `exit`, `memcpy`, `memset`,
      `memmove`, `memcmp` and `strlen`.
- [x] 1.6 Build `rpc_winshim.lib` from the six static-only symbols — `mainCRTStartup`, `atexit`,
      `_fltused`, `_tls_index`/`_tls_used`, `__chkstk` and ``const type_info::`vftable` `` —
      compiling with the bundled `zig cc` under `-ffreestanding -nostdinc` and archiving with
      `zig lib`.
- [x] 1.7 Write `tools/sysroot/x86_64-pc-windows-msvc/PROVENANCE.json` recording, per generated file,
      its bundled source path, the generating command, and the source licence, so the licence-audit
      scenario is mechanically checkable.
- [x] 1.8 Make the generator idempotent and verify it: run it twice on a clean toolkit and assert the
      two output trees match by name and content hash.
- [x] 1.9 Verify the generator completes on a machine with no Visual Studio, no Windows SDK and no
      network access.

## 2. Build script wiring

- [x] 2.1 In `scripts/rust_build_x64_win_native.ps1`, resolve the sysroot path and validate it before
      invoking `cargo`; on a missing or incomplete sysroot, fail with a message naming the sysroot
      path and `scripts/build_win_link_inputs.ps1`, and containing no reference to Visual Studio,
      `link.exe`, the MSVC linker or the Windows SDK.
- [x] 2.2 Add `/LIBPATH:<sysroot>` and `rpc_winshim.lib` to the link via
      `CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS` `-C link-arg=`, keeping the existing
      `Add-RustFlagIfMissing` idempotency helper.
- [x] 2.3 Extend `scripts/rust_build_isolation.ps1`'s scrub list with `LIB`, `INCLUDE`, `VCINSTALLDIR`,
      `VSINSTALLDIR` and `WindowsSdkDir`, and confirm `Restore-RustBuildEnvironment` restores them on
      both the success and failure paths.
- [x] 2.4 Retarget the C-compiler wrapper from `zig cc -target x86_64-windows-msvc` to
      `-target x86_64-windows-gnu` in UCRT mode, keeping the existing `--target`-stripping argument
      filter.
- [x] 2.5 Add the migration-phase fallback: when the sysroot is absent, log a deprecation warning and
      link the way the script does today, so the rollout is additive.
- [x] 2.6 Add the sysroot presence check to `scripts/rust_env.ps1` alongside the existing
      `rust-lld.exe` check, with the same message shape.

## 3. Self-containment check

- [x] 3.1 Rewrite `check_tool_x64_win.ps1` to build `sample/` for `x86_64-pc-windows-msvc` with the
      host MSVC and SDK environment scrubbed, then run the produced executable and fail if it does
      not exit successfully.
- [x] 3.2 Capture `lld-link /verbose` output, parse the resolved input paths, and fail listing every
      path outside the toolkit root together with the toolkit file that should have supplied it.
- [x] 3.3 Report the linker executable's resolved path on both the pass and fail paths, and assert it
      lies inside the toolkit root.
- [x] 3.4 Add the negative test: with the sysroot temporarily moved aside, assert the check reports
      missing link inputs and names the regeneration command, and does not report a missing linker.
- [x] 3.5 Extend the verification matrix beyond the pure-Rust sample with (a) a crate carrying a C
      build script and (b) a `catch_unwind` round-trip plus a panic-across-frames case, covering the
      two risks the design flags.
- [x] 3.6 Run the whole check on a clean Windows machine with no Visual Studio and no Windows SDK, and
      record the result.
- [x] 3.7 Update the existing PowerShell test suite for the new behaviour: teach
      `prepare_offline_release.tests.ps1`'s toolkit fixture about the generator, the sysroot and the
      fixture crate, and retarget `rust_build_env.tests.ps1`'s host-C-wrapper assertion from the MSVC
      Zig ABI to windows-gnu, adding coverage for the `/LIBPATH:` precedence and the conditional
      `+crt-static`.
- [x] 3.8 Make the /verbose parse encoding-independent: force UTF-8 decoding around the probe so a
      legacy console code page cannot swallow the record separators, temper the match so it can never
      span records, and report an unparseable capture as a defect in the check rather than as a host
      dependency. Verified under code page 936.

## 4. Packaging

- [x] 4.1 Invoke `scripts/build_win_link_inputs.ps1` from `scripts/prepare_offline_release.ps1` before
      staging, failing the release if generation fails.
- [x] 4.2 Add the sysroot tree and `scripts/build_win_link_inputs.ps1` to the `core` component file
      list so `install-layout.json` records every generated file.
- [x] 4.3 Run the self-containment check from `prepare_offline_release.ps1` and abort before writing
      the package if it fails, surfacing the check's output to the operator.
- [x] 4.4 Verify `scripts/finalize_offline_install.ps1` leaves the sysroot intact and that a fresh
      install with only default components builds the sample for `x86_64-pc-windows-msvc`.
- [x] 4.5 Rebuild the offline package end to end and confirm the recorded size delta is acceptable.

## 5. Documentation and downstream

- [x] 5.1 Correct `docs/customer/README-offline.md:60-62` to state that x64 Windows builds need no
      Visual Studio, MSVC linker or Windows SDK, and name Windows 10 / Server 2016 as the floor.
- [x] 5.2 Update `README.md:168` and the toolchain-layout section to describe the sysroot and the
      regeneration command.
- [x] 5.3 Document the residual limitation: a crate genuinely requiring MSVC headers still needs host
      MSVC, and say how that failure presents.
- [x] 5.4 Regenerate the desktop installer's split-volume manifest and SHA-256 values for
      `desktop/src/main/rust-toolkit-install.ts`, and confirm an existing installation upgrades
      cleanly.
- [x] 5.5 Remove the migration fallback from task 2.5 once a package has passed the check on a clean
      machine, making a missing sysroot a hard error.

## 6. Cleanup

- [x] 6.1 Remove the `x86_64-pc-windows-gnullvm` rust-std that was installed into `tools/rustup-home`
      while evaluating the alternative in Decision 1, so the shipped toolchain carries no unused
      target payload.
