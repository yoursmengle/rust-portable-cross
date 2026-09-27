## Context

See proposal.md. `rust_setup.ps1` already repairs target components and generates wrappers. `build_win_link_inputs.ps1` is an existing offline generator used by the release script but absent from the online setup path. All builds eventually call `Initialize-WindowsHostLinkInputs` and fail if the sysroot is absent.

## Goals / Non-Goals

**Goals:** Complete the existing setup command, reuse an intact sysroot on repeat runs, and fail with a named missing asset if setup cannot finish.

**Non-Goals:** Change public setup parameters, move the sysroot, upgrade compiler versions, or implement the transactional generator and cryptographic verification planned under U05/U07.

## Decisions

1. Add setup-private file and sysroot completeness helpers. Check non-zero length for cargo/rustc/rustup, Zig, rust-lld, rust-objcopy, and all existing wrapper files. Target payloads retain the shared manifest checker.
2. Require the full generated library set and PROVENANCE.json before reuse, not just the seven libraries the existing build readiness probe needs. If incomplete, invoke the current generator with `-Force` and then recheck the output.
3. Call the helper after Rust/Zig and wrapper preparation, before printing setup's completion message. The generator still reads only bundled Zig assets, so no new network source is introduced.
4. Exercise the regeneration branch with isolated fake tooling and a fake generator; use real bundled Zig and the existing Full lane for integration evidence. Do not mutate the developer's actual sysroot during the unit test.
5. Bootstrap rustup with `--default-toolchain none`, then use the existing pinned-toolchain installer with distribution-server fallback. Otherwise rustup-init's first download can fail on an inherited stale mirror before the fallback code runs.

## Risks / Trade-offs

- Generator currently deletes and recreates its output on `-Force` → U07 makes generation transactional; until then, only call it when the sysroot is incomplete.
- A nonempty file can still be wrong content → U05 adds trusted digest verification; U02's gate remains a structural completeness check.
- A current toolchain may have target components but be unable to build a large dependency tree offline → U04/U09 cover release installation and Cargo dependencies.

## Migration Plan

The setup entrypoint and options stay the same. Add the private helpers, test clean/repeat/repair/failure cases, run the default gate and Full build lane, then sync and archive this change.
