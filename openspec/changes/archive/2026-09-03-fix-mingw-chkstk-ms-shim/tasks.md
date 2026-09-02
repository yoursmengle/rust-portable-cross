## 1. Reproduce the failure

- [x] 1.1 Enlarge `test/fixtures/win_selfcontained/csrc/probe.c` with a function holding a
      multi-page local array whose address escapes to a non-inlinable callee, and confirm with
      `tools\zig\zig.exe cc -target x86_64-windows-gnu -S -O2` that the prologue emits
      `callq ___chkstk_ms`
- [x] 1.2 Declare and call it from `test/fixtures/win_selfcontained/src/main.rs`, asserting a value
      that depends on the whole buffer, and print a `large-frame: ok` line alongside the existing
      probes
- [x] 1.3 Run `.\check_tool_x64_win.ps1` against the unmodified shim and confirm it now fails with
      `undefined symbol: ___chkstk_ms` — this is the regression test proving the gap

## 2. Fix the shim

- [x] 2.1 In `New-ShimSource` (`scripts/build_win_link_inputs.ps1`), add the `___chkstk_ms` alias
      label plus its `.globl` / `.def ... .scl 2 .type 32 .endef` directives immediately before the
      existing `__chkstk:` label, sharing one body
- [x] 2.2 Update the comment above that `__asm__` block to state that the same routine serves the
      MSVC and MinGW spellings, and why both are needed given the GNU-target C wrapper
- [x] 2.3 Run `.\scripts\build_win_link_inputs.ps1 -Force` and confirm the regenerated
      `tools/sysroot/x86_64-pc-windows-msvc/lib/rpc_winshim.lib` now defines `___chkstk_ms` as well
      as `__chkstk`
- [x] 2.4 Confirm `tools/sysroot/x86_64-pc-windows-msvc/PROVENANCE.json` was rewritten with the new
      `rpc_winshim.lib` hash

## 3. Guard against regression in the generator

- [x] 3.1 Add `$script:RequiredShimSymbols` next to `$script:RequiredCrtExports`, listing
      `__chkstk`, `___chkstk_ms`, `_fltused`, `mainCRTStartup`, `atexit`, `_tls_used`, `_tls_index`
- [x] 3.2 Verify the produced shim object or archive defines every listed symbol before
      `New-ShimArchive` returns, throwing with the missing names and the generator command when it
      does not
- [x] 3.3 Prove the guard fires: temporarily drop a symbol from the shim source, confirm the
      generator fails naming it, then restore

## 4. Guard against regression in the check

- [x] 4.1 Add a section to `check_tool_x64_win.ps1` that asserts the shipped `rpc_winshim.lib`
      defines each required symbol, failing with the symbol name and
      `.\scripts\build_win_link_inputs.ps1` as the remedy
- [x] 4.2 Keep the assertion consistent with the generator's list rather than duplicating a second
      hand-maintained copy that can drift

## 5. CRT functions the platform exports only as header inlines

- [x] 5.1 Confirm the gap: build a real `zstd` project through the toolkit and record which
      symbols the link reports, then check them against the exports in the bundled
      `ucrtbase.def.in` to establish that the whole printf and scanf family is absent
- [x] 5.2 Add narrow-character forwarders to `New-ShimSource`: `printf`, `fprintf`, `sprintf`,
      `snprintf`, `_snprintf`, `_scprintf`, `scanf`, `fscanf`, `sscanf` and each one's
      `v`-prefixed variant, each carrying the option flags its Microsoft header inline passes
- [x] 5.3 Declare the primitives the shim calls (`__stdio_common_vfprintf`,
      `__stdio_common_vsprintf`, `__stdio_common_vfscanf`, `__stdio_common_vsscanf`,
      `__acrt_iob_func`) in the shim itself, and use `__builtin_va_list` rather than `stdarg.h`,
      so the source stays compatible with the existing `-nostdinc -ffreestanding` compile
- [x] 5.4 Add `-fno-builtin` to the shim compile so clang cannot rewrite a forwarder body into a
      call to itself
- [x] 5.5 Extend `$script:RequiredShimSymbols` with the new names and regenerate the sysroot
- [x] 5.6 Extend the `win_selfcontained` fixture to assert observable behaviour, not just
      linking: `snprintf` truncation and return value, `_snprintf`'s legacy non-termination,
      `sprintf` output, and `sscanf` parsing - so a wrong option flag fails the check

## 6. Verify end to end

- [x] 6.1 Run `.\check_tool_x64_win.ps1` and confirm every section passes, including the enlarged
      fixture and the new symbol assertion
- [x] 6.2 Build a project that reproduced the original failure with a cleared cache
      (`cargo clean -p zstd-sys`, or a fresh `target/`) through
      `.\scripts\rust_build_x64_win_native.ps1` and confirm it links and runs
- [x] 6.3 Run the existing PowerShell test suite under `test/` and confirm nothing regressed

## 7. Documentation and packaging

- [x] 7.1 Update the `build_win_link_inputs.ps1` section of `README.md` where it enumerates what the
      shim supplies, naming both stack-probe spellings and the reason the MinGW one is needed
- [x] 7.2 Rebuild the offline package with `.\scripts\prepare_offline_release.ps1` so the shipped
      `core` component carries the corrected shim, and confirm the packaged
      `rpc_winshim.lib` matches the regenerated one
