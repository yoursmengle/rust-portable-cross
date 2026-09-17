## Purpose

Guarantees that every target advertised by the portable toolchain has the real Rust standard-library
payload needed by its execution model, so rustup metadata cannot mask a broken offline release.

## ADDED Requirements

### Requirement: Hosted targets ship complete rust-std payloads

The toolkit SHALL provide complete, non-empty `rust-std` payloads for
`x86_64-pc-windows-msvc`, `armv7-unknown-linux-musleabihf`, and `aarch64-unknown-linux-musl` in the
same managed toolchain as the active `rustc`. A payload check SHALL verify the target libdir and the
manifest-listed files, including `libstd-*.rlib`, `libstd-*.rmeta`, `libcore`, `liballoc`, and
`libcompiler_builtins` artifacts.

#### Scenario: Hosted target payload is usable

- **WHEN** the toolkit is provisioned with all three hosted target components
- **THEN** the payload check SHALL find each target libdir through the active `rustc`
- **AND** SHALL report success only when the required manifest-listed files exist and are non-empty
- **AND** each hosted target SHALL expose both a `libstd-*.rlib` and a `libstd-*.rmeta`

#### Scenario: rustup metadata exists but libstd is missing

- **WHEN** `rustup target list --installed` reports a hosted target but its libdir lacks `libstd`
- **THEN** the payload check SHALL report that target as incomplete
- **AND** release or installation validation SHALL NOT report the toolchain as usable

#### Scenario: A supporting standard-library file is missing

- **WHEN** a hosted target's manifest exists but any listed file is absent or zero-length
- **THEN** the payload check SHALL fail
- **AND** the diagnostic SHALL name the target and missing or empty relative file

### Requirement: Bare-metal targets use no_std acceptance criteria

The toolkit SHALL treat `thumbv7em-none-eabihf` as a `no_std` target. Its payload check SHALL require
the target libdir and non-empty `libcore`, `liballoc`, and `libcompiler_builtins` artifacts, but SHALL
NOT require `libstd`.

#### Scenario: Bare-metal payload is complete without libstd

- **WHEN** the thumb target contains its manifest-listed core/alloc/compiler-builtins payloads and no
  `libstd` file
- **THEN** the payload check SHALL pass

#### Scenario: Bare-metal payload is incomplete

- **WHEN** the thumb target libdir or a required core/alloc/compiler-builtins artifact is absent or
  empty
- **THEN** the payload check SHALL fail
- **AND** the diagnostic SHALL identify the thumb target and missing or empty artifact

### Requirement: Setup and release flows repair incomplete target payloads

The setup and offline release flows SHALL use the same payload completeness criteria as validation.
When a hosted or bare-metal payload is incomplete, they SHALL attempt the existing managed
`rustup target add` repair path with the portable `RUSTUP_HOME`, `CARGO_HOME`, and toolchain selected;
they SHALL fail if the repaired payload remains incomplete.

#### Scenario: Missing payload is repaired

- **WHEN** a required target directory or manifest-listed payload file is removed before offline
  staging
- **THEN** the release flow SHALL invoke the managed target repair path
- **AND** SHALL continue only after the complete payload is present

#### Scenario: Repair cannot restore the payload

- **WHEN** target repair exits successfully but a required payload file is still missing or empty
- **THEN** the flow SHALL abort
- **AND** SHALL name the target and the remaining missing artifact rather than silently packaging
  metadata-only state

### Requirement: Payload validation is version-bound and offline-verifiable

Payload validation SHALL resolve target libdirs from the active managed `rustc`, use the same toolchain
that reports the host version and commit hash, and SHALL never fall back to a system Rust installation.
Offline package validation SHALL be able to prove the payload state without network access.

#### Scenario: System Rust is present but managed Rust is selected

- **WHEN** a system Rust installation is also on `PATH`
- **THEN** setup, staging, and install validation SHALL inspect the managed toolchain's target libdirs
- **AND** SHALL not accept a system target directory as evidence for the package

#### Scenario: Installed offline package is checked without network

- **WHEN** post-install validation runs with network access disabled
- **THEN** it SHALL validate the hosted and bare-metal payloads from the installed files
- **AND** SHALL report a deterministic pass or a target-specific missing/empty-file failure
