## ADDED Requirements

### Requirement: Target artifact identity is a publication gate
After staged and installed smoke builds, the release SHALL inspect the generated Windows, ARMv7, AArch64, and Thumbv7EM artifacts before an installer or split manifest is published.

#### Scenario: Installed output has wrong architecture
- **WHEN** a build exits successfully but emits an artifact for an unexpected architecture
- **THEN** staged or installed release validation fails and the public manifest stays unchanged
