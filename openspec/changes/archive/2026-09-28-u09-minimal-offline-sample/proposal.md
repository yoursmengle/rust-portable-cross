## Why

The installed release contains `sample/Cargo.lock` but none of its registry dependencies. A fresh customer machine with an empty Cargo cache cannot build the advertised sample offline, even though the toolchain and dependency-free smoke fixture work.

## What Changes

- Package only the registry archives and sparse index entries required by the sample lockfile in the managed Cargo home, validating every archive against its lockfile checksum before staging.
- Record the bundled dependency set and licenses without carrying personal Cargo configuration or credentials into the installer.
- Make release validation build the complete sample from an isolated install with an empty external Cargo cache and blocked process-level network access.
- Report a missing or corrupt offline dependency by crate name and version before a release is published.

## Capabilities

### New Capabilities

- `offline-sample-dependencies`: A released installation can build the bundled sample offline using its own bounded, integrity-checked dependency cache.

### Modified Capabilities

- `delivered-release-verification`: The release gate also proves the complete sample builds with the delivered dependency cache.

## Impact

Internal release preparation, payload indexing, release smoke, staged Cargo cache contents, and customer dependency documentation. Public command names, parameters, target names, lockfile, layout schema, and normal Cargo online/offline choices remain unchanged.
