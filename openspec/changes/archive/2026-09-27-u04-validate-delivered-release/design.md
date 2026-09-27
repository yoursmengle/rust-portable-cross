## Context

See proposal.md. Staging contains `core` and three target overlays; Inno Setup copies those into one installation root and runs the current finalizer. The finalizer treats optional health checks as best-effort, so the release gate needs its own strict validation. The installed product currently uses this installer AppId on the validation machine, requiring reversible registry handling for a second disposable installation.

## Goals / Non-Goals

**Goals:** Verify byte integrity and actual builds from both staged and EXE-installed payloads while keeping `build.ps1` arguments, installer naming, layout schema, and customer build commands intact.

**Non-Goals:** Package external dependencies for the existing full sample (U09); change the customer's best-effort post-install warning semantics; make administrator privileges a release prerequisite.

## Decisions

1. A private `release_validation.ps1` helper will expose a read-only staging audit and an installed-root smoke check. The staging audit will reuse the U05 integrity index, verify version and the exact pinned compiler, and check each target and Windows link-input provenance. The same audit runs after fresh staging and `-SkipStaging`.
2. The helper will copy staged component trees into a UUID-named temporary installation root, invoke the shipped finalizer without its best-effort `-Validate` switch, then independently run strict health and build checks. This reproduces the install layout and avoids deleting or mutating source tools. Validation uses a separate PowerShell process with PATH limited to OS paths and the installed toolkit, `RUSTUP_AUTO_INSTALL=0`, and `CARGO_NET_OFFLINE=true`.
3. Ship a dependency-free smoke crate whose local proc macro and `build.rs` run on the Windows host while ARMv7 and AArch64 outputs link with the bundled Zig wrappers. Reuse the existing Windows C fixture and embedded sample for C compilation and BIN/HEX checks. This tests toolchain capability without waiting for U09's external package cache.
4. `build.ps1` will validate staging, build the expected EXE, install it silently into a UUID-named directory, strictly validate that installed root, and only then export and publish. `DisableDirPage=yes` makes Inno ignore `/DIR`, so a private process environment variable selects that directory only during release validation; ordinary installations retain the same default. The verifier launches Inno with process-tree waiting and a short TEMP path to stay within legacy Windows path limits. If an installation with the same AppId already exists, the verifier backs up and restores the per-user uninstall registration and PATH around the disposable run; it keeps the backup outside the disposable directory until restoration is verified. Split publication remains the commit point implemented by U07.

## Risks / Trade-offs

- [Large copies and repeated hashes lengthen release builds] → Run staging and installation verification only for release preparation, with quick source preflight retained.
- [A deep validation directory exceeds Inno's effective file path limit] → Use a short, UUID-named TEMP root and check Inno's actual installed location.
- [The current unprivileged account cannot enforce machine-wide network isolation] → Force Rust/Cargo offline behavior and a minimal executable PATH, and record this limitation; a network-disabled validation machine can run the same gate without code changes.
- [Silent Inno installation changes the user's AppId registration and PATH] → Preserve exact prior registry and PATH state, use a disposable path, and restore in `finally`; abort if the installer points outside that path.

## Migration Plan

The new gate runs automatically for the existing release command. Rollback is the U04 commit reversal; no customer layout or command migration is needed. U07 keeps the public split manifest on the previous verified version until the new gate finishes.
