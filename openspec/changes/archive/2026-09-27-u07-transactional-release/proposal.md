## Why

Release preparation deletes working staging and Windows link inputs before replacements are ready. Fixed temporary paths and in-place publication can also let concurrent processes overwrite each other's files or expose a manifest whose parts are incomplete.

## What Changes

- Prepare staging and Windows sysroot in private same-volume directories and promote only verified replacements, retaining a recoverable previous state.
- Coordinate toolkit mutations and builds using a root-scoped process lock; repair Rust targets in an isolated rustup-home copy.
- Give each native wrapper and self-containment probe its own temporary directory, and run missing-sysroot diagnostics without moving live files.
- Assemble and verify release parts privately, reject conflicting same-version bytes, and atomically publish the manifest only after every part is present.
- Preserve command parameters, artifact names, manifest fields, and the installed toolchain layout.

## Capabilities

### New Capabilities

- `toolkit-transactional-updates`: Managed toolkit state survives interruption and conflicting writers without exposing partial payloads.
- `offline-publication-transaction`: Public download manifests refer only to verified immutable parts.

### Modified Capabilities

None.

## Impact

Touches setup, target repair, sysroot generation, staging, build wrappers/checks, installer publication, and isolated failure/concurrency tests. Internal lock and recovery metadata are private implementation details.
