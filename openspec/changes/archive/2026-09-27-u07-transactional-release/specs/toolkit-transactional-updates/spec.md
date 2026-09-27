## Purpose

Keep the currently usable portable toolchain and staged installer files available when preparation is interrupted, and prevent simultaneous operations from observing or producing mixed managed state.

## ADDED Requirements

### Requirement: Managed replacements preserve the last good state

Staging and Windows sysroot regeneration SHALL create and verify replacements away from the active path, then promote them with recovery for failures or interruption. A failed build or occupied destination SHALL leave the previously usable state recoverable.

#### Scenario: Preparation fails before promotion
- **WHEN** copying or generating a replacement fails
- **THEN** the active staging or sysroot remains usable and no partial replacement appears there

#### Scenario: Promotion is interrupted
- **WHEN** the process exits after setting aside the old directory but before promoting the new one
- **THEN** the next preparation recovers the old directory before continuing

### Requirement: Conflicting toolkit operations are coordinated

Mutations and builds for the same normalized toolkit root SHALL coordinate across processes so a build cannot consume a partially switched managed payload. Distinct roots SHALL remain independent, and an exited writer SHALL not permanently block future work.

#### Scenario: Two writers target one root
- **WHEN** two preparations or repairs run against the same toolkit root
- **THEN** their managed mutations do not interleave

#### Scenario: Writer exits unexpectedly
- **WHEN** a lock holder terminates without cleanup
- **THEN** a later process can recover and continue without relying only on a reused PID

#### Scenario: Different roots
- **WHEN** two portable copies build or prepare at once
- **THEN** they do not share mutable temporary wrapper or probe files

### Requirement: Rust target repair does not destroy the active toolchain

When preparing an existing toolkit with missing or damaged Rust target components, repair SHALL occur in an isolated managed copy and only replace the active rustup state after the repaired compiler and target payloads pass verification.

#### Scenario: Repair fails
- **WHEN** rustup repair or verification fails
- **THEN** the current rustup home and installed components remain available

### Requirement: Self-containment diagnostics leave active inputs in place

The negative missing-sysroot check SHALL exercise the build's missing-input guard without moving the active Windows sysroot.

#### Scenario: Another build is using the sysroot
- **WHEN** the negative check runs while a separate build uses the real sysroot
- **THEN** the real files remain in place and the check still reports the intended missing-input diagnostic
