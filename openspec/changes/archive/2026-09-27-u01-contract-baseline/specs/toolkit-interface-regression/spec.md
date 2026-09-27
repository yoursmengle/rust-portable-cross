## Purpose

Protect existing toolkit consumers from accidental changes to public commands, install layout, and metadata while P0 reliability improvements alter internal implementation.

## ADDED Requirements

### Requirement: Public command signatures remain stable
The default repository gate SHALL compare the supported entrypoint names, parameters, types, defaults, and constrained values against a checked-in baseline without requiring a downloaded toolchain.

#### Scenario: Supported signature remains unchanged
- **WHEN** all supported script entrypoints retain their baseline signatures
- **THEN** the interface regression check passes

#### Scenario: A public signature drifts
- **WHEN** a supported script parameter is added, removed, renamed, or changes type, default, or allowed values
- **THEN** the check fails and identifies the entrypoint and differing parameter

### Requirement: Consumer-facing layout and metadata remain stable
The default gate SHALL check the published target triples, installer component selection, Windows sysroot location, wrapper names, and documented JSON field shapes against a checked-in baseline.

#### Scenario: Layout and metadata agree with the baseline
- **WHEN** the checked toolkit retains the published paths, targets, and metadata shapes
- **THEN** the interface regression check passes

#### Scenario: A published path or field changes
- **WHEN** a target triple, Windows sysroot path, required wrapper name, or published JSON field changes
- **THEN** the check fails with a diagnostic naming the changed contract

### Requirement: Documentation matches current installation behavior
Customer-facing installation documentation SHALL describe the installer's actual all-target installation behavior without changing its component metadata or finalize parameters.

#### Scenario: Customer reads target selection guidance
- **WHEN** a customer reads the offline installation guide
- **THEN** it states that the current installer installs armv7, aarch64, and thumbv7em support together
