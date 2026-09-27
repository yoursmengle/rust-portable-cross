# toolkit-setup-completeness Specification

## Purpose

Guarantee that the existing one-command source setup reports success only after it has prepared every bundled tool and link input needed by the supported Windows and cross-target build scripts.

## Requirements

### Requirement: Successful setup yields a complete managed toolchain
The setup command SHALL provision the pinned Rust and Zig tools, the supported target payloads, the bundled host linker and image converter, every required wrapper, and the Windows link-input sysroot at its existing published path before reporting success.

#### Scenario: Fresh source checkout
- **WHEN** setup runs in a new checkout with no downloaded toolchain
- **THEN** the required files and target components are present and non-empty
- **AND** every existing build entrypoint can find its bundled host link inputs without a separate preparation command

#### Scenario: Required tool remains absent
- **WHEN** a required executable, wrapper, target payload, or Windows link input is still absent after setup
- **THEN** setup fails and identifies the missing asset instead of reporting completion

### Requirement: Repeated setup repairs incomplete managed assets
Running setup again SHALL preserve complete assets and restore missing or incomplete managed target and Windows link-input files while retaining the existing `-Force` cache reset behavior.

#### Scenario: Already complete installation
- **WHEN** setup is rerun and all managed assets are complete
- **THEN** the Windows link-input sysroot is reused without regeneration

#### Scenario: Incomplete sysroot
- **WHEN** a required Windows import library or its provenance record is absent or empty
- **THEN** setup regenerates the sysroot from the bundled Zig assets and verifies the result

#### Scenario: Incomplete target component
- **WHEN** rustup metadata exists but an installed target payload is incomplete
- **THEN** setup uses the managed repair path and fails if the component remains incomplete
