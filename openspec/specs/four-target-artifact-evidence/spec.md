# four-target-artifact-evidence Specification

## Purpose

Make release output evidence reflect the actual machine format, ABI, runtime dependencies, and firmware load addresses of the four supported target artifacts instead of treating any nonempty file as success.

## Requirements

### Requirement: Host and Linux artifacts match supported targets
The release SHALL reject a Windows output that is not x64 PE with only the approved operating-system DLL dependencies. It SHALL reject Linux outputs whose ELF machine, word size, ARM hard-float ABI, or static-link baseline differs from the supported ARMv7 and AArch64 targets.

#### Scenario: Wrong target artifact
- **WHEN** an artifact is replaced with a binary for a different machine or format
- **THEN** release validation identifies the artifact and expected target and blocks publication

#### Scenario: Unexpected runtime dependency
- **WHEN** a Windows binary imports an unapproved DLL or a Linux binary needs a dynamic loader
- **THEN** release validation reports the dependency and blocks publication

### Requirement: Embedded image fits its active-app slot
The release SHALL verify the Thumbv7EM ELF entry point, BIN vector-table stack and reset values, image capacity, and Intel HEX record addresses/checksums against the HEM6801E active-app flash range.

#### Scenario: Wrong vector or HEX address
- **WHEN** the vector table or Intel HEX data points outside the configured application slot
- **THEN** release validation blocks publication with the offending value

### Requirement: Full CI runs four target checks
The Full CI lane SHALL execute all four existing target checks and report each actual result; a runner error SHALL fail visibly rather than standing in for a target result.

#### Scenario: Full lane on a provisioned checkout
- **WHEN** the pinned toolchain is installed and Full CI runs
- **THEN** each target check is invoked in a child PowerShell process and its exit status is reported
