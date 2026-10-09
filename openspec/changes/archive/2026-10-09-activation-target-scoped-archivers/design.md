## Context

See proposal.md (Why). The relevant current state is:

- `scripts/rust_env.ps1` is the only place that sets the unsuffixed `AR` / `RANLIB` for interactive use. Every `rust_build_*.ps1` first calls `Clear-RustBuildEnvironment` (`rust_build_isolation.ps1`), which already lists `AR`, `RANLIB`, and all target-scoped variants. Those build scripts then set what they need: `rust_build_armv7.ps1` / `rust_build_aarch64.ps1` set target-scoped variables only; `rust_build_thumbv7em.ps1` sets none; `rust_build_x64_win_native.ps1` sets `zig-lib.cmd` plus a zig-cc wrapper. That wrapper is generated into a per-run temp directory and is not shipped in `tools/wrappers`.
- In an activated shell, a host `cargo build` already uses cc-rs's default discovery for the host C compiler (VS `cl.exe`) and cargo's default MSVC linker. Activation does not install the host cargo config that points at `rust-lld` and the bundled link inputs. So VS-free host builds are a promise of `rust_build_x64_win_native.ps1` only, not of the activated shell.
- `rust_env.ps1` already reconciles state left by a previous activation (`$previousToolkitRoot` → `Set-ToolkitPathPrefix`). Leftover archiver cleanup follows the same pattern.

## Goals / Non-Goals

**Goals:**
- Direct `cargo` in an activated shell produces host archives with the same tool cc-rs would pick without activation.
- Cross-target C builds in an activated shell keep using `zig-ar` / `zig-ranlib`.
- Shells activated by an older toolkit version are fixed simply by re-activating.

**Non-Goals:**
- VS-free host C compilation or linking in the activated shell, including the "optional" `AR_x86_64_pc_windows_msvc = zig-lib.cmd`. See Decision 2.
- Changing any `rust_build_*.ps1`, wrapper, or release payload.

## Decisions

1. **Remove the unsuffixed `AR` / `RANLIB` assignments and keep only the 8 target-scoped assignments.** cc-rs checks `AR_<target>` (both spellings) before `TARGET_AR` and `AR`, so the scoped variables fully cover armv7/aarch64. *Alternative:* set `AR_x86_64_pc_windows_msvc` to something MSVC-compatible to override the global value. Rejected because it still leaves a GNU fallback for any other target the user builds, such as `wasm32` or `x86_64-pc-windows-gnu`.

2. **Do not set any host (`x86_64-pc-windows-msvc`) archiver or compiler in activation.** Setting only `AR_x86_64_pc_windows_msvc=zig-lib.cmd` would be half of a VS-free story. `cl.exe` and `link.exe` would still come from VS, and mixing a zig-lib archive with `cl.exe` objects adds risk for no gain. Doing the full version would mean shipping the x64 zig-cc wrapper persistently and installing the host cargo linker config into the user's shell or project. That is a separate capability decision. This keeps the activated shell's host behaviour identical to an un-activated shell plus the toolkit's `rustc`. *Alternative:* full VS-free activation. Deferred to its own change if wanted.

3. **Reconcile leftovers by exact value match.** Remove `AR` only if it equals `zig-ar.cmd`, and `RANLIB` only if it equals `zig-ranlib.cmd` (the literal values every past version wrote). Any other value is kept and triggers `Write-Warning`. Matching is case-insensitive, like Windows file names. *Alternative:* always clear `AR` / `RANLIB`. Rejected because it silently discards user configuration. Another alternative is to use a marker variable recording what the toolkit set. Rejected because older activations never wrote such a marker, so it would not fix existing shells.

4. **Testing approach.**
   - Unit-level: dot-source `rust_env.ps1` in a child `pwsh` against a provisioned toolkit (as the existing activation tests do), with seeded `AR` / `RANLIB`. Then assert on the resulting environment and the warning stream. This covers fresh activation, a leftover value, a user value, and double activation.
   - Skips: `ci.ps1` previously treated any suite exit of 0 as PASS, so a suite had no way to skip honestly. Add a reserved exit code (3) plus a `SKIP: <reason>` line, reported as SKIP / NOT RUN. *Alternative:* exit 0 with a message. Rejected because it contradicts the gate's rule that a skip must never read as coverage.
   - Full-lane placement: `-Full` previously ran only the public `check_tool_*.ps1` entry points, which are locked by the interface contract. Add a `test/full/*.ps1` hook instead of extending a public check with a VS-dependent step. The default lane's discovery is non-recursive, so these scripts never run in the commit hook.
   - End-to-end: in an activated child shell, run `cargo build --offline` for the host on `sample`. `sample` already depends on `ring` → `cc` from the offline lock, so it reproduces the `-out:` / `-nologo` archiver call without adding a dependency. Before the fix this fails with `unknown option n`. This test needs a host C toolchain discoverable by cc-rs (VS). Without one, it is skipped with an explicit message rather than reported as passing.

## Risks / Trade-offs

- [Users who relied on the global `AR` for some other GNU-style target, such as `x86_64-unknown-linux-musl`] → Not a supported target of this toolkit. The proposal and release notes say to set `AR_<triple>` explicitly.
- [The end-to-end test depends on VS being present] → It is skipped explicitly on a machine without VS. The unit-level assertions still guard the defect on every run.
- [Host C builds in an activated shell still need VS] → Unchanged from today and documented as a non-goal. `rust_build_x64_win_native.ps1` remains the VS-free path.

## Migration Plan

No data migration. Existing shells are fixed by running the activation script again, which removes the leftover values. Rollback means reverting `rust_env.ps1`.
