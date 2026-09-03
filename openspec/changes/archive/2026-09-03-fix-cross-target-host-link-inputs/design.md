## Context

See `proposal.md` — Why. The design-relevant facts:

- Cargo always compiles `build.rs` and proc-macros for the host triple
  (`x86_64-pc-windows-msvc` here), even when `--target` is
  `thumbv7em-none-eabihf` / `armv7-unknown-linux-musleabihf` /
  `aarch64-unknown-linux-musl`. The customer failure is that host link, not
  the embedded firmware link: `rust-lld -flavor link` cannot open
  `kernel32.lib`, `ntdll.lib`, `userenv.lib`, `ws2_32.lib`, `dbghelp.lib`.
- `rust_build_x64_win_native.ps1` already validates
  `tools\sysroot\x86_64-pc-windows-msvc\lib` and passes
  `-C link-arg=/LIBPATH:$winSysrootLib` plus `-C link-arg=rpc_winshim.lib`.
  `lld-link` searches `/LIBPATH:` before `LIB`, so this wins over `rustc`'s
  registry probe for Visual Studio. The three cross-target scripts only set
  `CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER=rust-lld` and
  `-C linker-flavor=lld-link`.
- All four build scripts already dot-source `scripts/rust_build_isolation.ps1`,
  which clears `LIB` / `INCLUDE` / `VCINSTALLDIR` / `WindowsSdkDir` and restores
  them in `finally`. That isolation is why a developer machine (VS present,
  `rustc` still injects SDK `LIB` from the registry) and a customer machine
  (no VS, no `LIB`) diverge.
- `check_tool_thumbv7em.ps1` is a thin wrapper around
  `rust_build_thumbv7em.ps1`. Fixing the build script fixes the check.
- The sysroot is already in the always-installed `core` component. This change
  is scripts, tests, and docs — not a new payload.

## Goals / Non-Goals

**Goals:**

- One shared helper owns host-link validation and `CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_*`
  flags, so the four build scripts cannot drift again.
- A `thumbv7em` (and other cross-target) toolkit build on a machine without
  Visual Studio links host artifacts the same way the x64 native path already
  does.
- Missing sysroot fails before `cargo` with the existing regeneration
  diagnostic, including when the cargo `--target` is not Windows.

**Non-Goals:**

- Changing the `thumbv7em` target linker, `link.x`, or `sample_embedded`
  firmware behaviour.
- Teaching `rust_env.ps1` to export host-link flags so ad-hoc
  `cargo build --target ...` after activation is self-contained (proposal
  non-goal).
- Adding the x64 native Zig `windows-gnu` C wrapper to the cross-target
  scripts. Host C in a cross-target `build.rs` remains the documented
  remaining MSVC-headers limitation.
- Expanding `check_tool_thumbv7em.ps1` into a `/verbose` provenance dump like
  `check_tool_x64_win.ps1`. Success of the isolated host link is the
  observable contract.
- Regenerating or reshaping the sysroot.

## Decisions

### Decision 1: Put the host-link setup in `rust_build_isolation.ps1`

Add `Initialize-WindowsHostLinkInputs -ToolkitRoot <path>` next to the
existing `Add-RustBuildFlagIfMissing` / `Clear-RustBuildEnvironment`
helpers. Every build script already loads that file, so the call site is
one line after `Clear-RustBuildEnvironment` and
`Repair-CargoHostTargetConfig`.

The helper:

1. Resolves `tools\sysroot\x86_64-pc-windows-msvc\lib` under the toolkit root.
2. Requires the same library set the x64 native script already lists
   (`kernel32`, `ntdll`, `userenv`, `ws2_32`, `dbghelp`, `msvcrt`,
   `rpc_winshim`).
3. Throws the existing here-string (path, missing names,
   `.\scripts\build_win_link_inputs.ps1`, "not a missing linker") if any
   file is absent.
4. Sets `CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER=rust-lld`.
5. Appends, via `Add-RustBuildFlagIfMissing`:
   `-C linker-flavor=lld-link`, `-C link-arg=/LIBPATH:$winSysrootLib`,
   `-C link-arg=rpc_winshim.lib`.

Alternatives considered:

- *Copy the three flags into each cross-target script.* That is the current
  pattern for `rust-lld` + `lld-link`, and it is exactly how `/LIBPATH:` was
  omitted. Rejected.
- *Export the flags from `rust_env.ps1`.* Activation would then make ad-hoc
  cargo work, but `rust_env.ps1` does not isolate `LIB` and is left in the
  user's session. Mixing "activate" with "scrub and pin for this build"
  would make a later `Restore-RustBuildEnvironment` surprising. Rejected for
  this change; activation remains informational.

### Decision 2: Refactor the x64 native script onto the same helper

`rust_build_x64_win_native.ps1` keeps its Zig C wrapper, `HOST_CC` / `CC` /
`AR` / `RANLIB` wiring, and `+crt-static` prohibition. It drops its private
`Test-WindowsLinkInputs` / required-library list / `/LIBPATH:` /
`rpc_winshim.lib` setup and calls `Initialize-WindowsHostLinkInputs`
instead.

One list of required libraries and one diagnostic string. The x64 native
path stays behaviourally identical.

### Decision 3: Keep `rust_env.ps1` as a warning, not a throw

Sourcing `rust_env.ps1` is used for `rustc -V`, listing targets, and
activation. A missing sysroot must not prevent that. Change the comment and
warning from "cross targets do not need them" to "every toolkit cargo build
that links a host artifact needs them, including `thumbv7em` / `armv7` /
`aarch64`". The throw stays in the helper, which only the build scripts
call.

### Decision 4: Leave the check scripts as wrappers

`check_tool_thumbv7em.ps1` already: sources `rust_env.ps1`, then runs
`rust_build_thumbv7em.ps1`, which already Save/Clear/Restore the MSVC env
list. After Decision 1, a missing sysroot throws before `cargo` with the
link-input diagnosis, and a present sysroot lets the host `build.rs` of
`sample_embedded` link on a machine without Visual Studio.

Duplicating `check_tool_x64_win.ps1`'s `/verbose` provenance probe onto the
firmware path would assert the same `/LIBPATH:` the helper already sets, at
the cost of a second parser. Not needed to satisfy the spec.

### Decision 5: Assert the helper, not per-script flag strings

`test/rust_build_env.tests.ps1` currently greps each script body for
`rust-lld` / `lld-link`, and greps only the x64 script for `/LIBPATH:` and
`rpc_winshim.lib`. After the extract, those strings live in the isolation
helper.

Update the tests to:

- Assert the isolation helper defines `Initialize-WindowsHostLinkInputs`,
  contains `/LIBPATH:`, `rpc_winshim.lib`, and the
  `build_win_link_inputs.ps1` diagnostic, and does not request
  `+crt-static`.
- Assert each of the four build scripts calls
  `Initialize-WindowsHostLinkInputs` after `Clear-RustBuildEnvironment` and
  before `cargo build`.
- Keep the existing per-target linker / Zig-wrapper assertions on the
  musl and thumbv7em scripts.

## Risks / Trade-offs

- **[Risk]** A crate whose host `build.rs` compiles C that needs Microsoft
  headers still fails on a bare machine during a cross-target build.
  → **Mitigation:** documented remaining limitation; same as the x64 native
  path. This change only closes the Rust-std host link (`kernel32.lib`
  etc.), which is the reported failure.

- **[Risk]** `/LIBPATH:$winSysrootLib` is unquoted. An install path with
  spaces would break the host link.
  → **Mitigation:** the Inno default is `D:\rust-portable-cross` or
  `C:\rust-portable-cross` and `DisableDirPage=yes`. The x64 native path
  already uses the same unquoted form; do not invent a new quoting scheme
  here.

- **[Risk]** Existing installed copies keep the old scripts until they
  install an updated package.
  → **Mitigation:** this is a scripts-only fix in the `core` payload.
  Rollback is reinstalling the previous installer. No sysroot or layout
  change.

## Migration Plan

- Ship in the next offline package. No layout / component-id change.
- Operators who already installed a package that contains the sysroot only
  need the updated scripts (or a full reinstall).
- Rollback: previous installer. The helper is additive; leaving it unused
  restores the old "works only if Visual Studio is installed" behaviour.

## Open Questions

None. Host C during cross-target builds is a known leftover, not a blocker
for the reported `kernel32.lib` failure.
