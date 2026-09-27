## ADDED Requirements

### Requirement: Complete sample is an offline release gate
The staged and installed release SHALL build the bundled full sample under an isolated Cargo environment with blocked process-level network access before the public installer manifest changes.

#### Scenario: Missing sample dependency
- **WHEN** a staged or installed sample dependency is absent or corrupt
- **THEN** the release validation fails and no new public installer manifest is published

#### Scenario: All supported targets
- **WHEN** the complete sample and embedded sample are built for the Windows host, ARMv7 Linux, AArch64 Linux, and Thumbv7EM targets
- **THEN** each build uses the installed toolchain and either succeeds or blocks publication with a diagnostic
