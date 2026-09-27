# offline-sample-dependencies Specification

## Purpose

Provide a bounded, integrity-checked copy of the bundled sample's exact registry dependencies so a fresh installed toolchain can build that sample without access to a user Cargo cache or network.

## Requirements

### Requirement: Sample dependencies ship with the installation
The release SHALL include every registry dependency required by the bundled sample lockfile for supported target builds in the managed Cargo home. It SHALL preserve the existing sample build commands and SHALL NOT require customers to force offline mode for ordinary work.

#### Scenario: Fresh offline installation
- **WHEN** the installation is run with an empty external Cargo cache and no network access
- **THEN** the bundled sample builds using the installed toolchain and its managed dependency cache

#### Scenario: Missing required archive
- **WHEN** a locked dependency archive is absent from the release source cache
- **THEN** release preparation fails with its crate name and version before publication

### Requirement: Dependency payload is bounded and traceable
The release SHALL select dependencies from the sample lockfile, check each archive against its lockfile digest, publish a dependency and license manifest, and exclude user Cargo credentials, tokens, and personal configuration.

#### Scenario: Corrupt cached archive
- **WHEN** a cached archive differs from its lockfile checksum
- **THEN** preparation rejects the archive and names the affected crate

#### Scenario: Unrelated Cargo cache contents
- **WHEN** the release source Cargo home contains other projects' dependencies or local configuration
- **THEN** only the sample's locked packages and required public registry metadata enter the release
