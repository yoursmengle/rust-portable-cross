# toolchain-self-containment-check Specification

## Purpose
Turns "this is a portable toolchain with no external dependencies" from a documentation claim into a
checkable property, by providing a check that fails whenever a build consumes a file from outside the
toolkit root.
## Requirements
### Requirement: Self-containment check for the Windows host target

The toolkit SHALL provide a check that builds the bundled sample for `x86_64-pc-windows-msvc` under a
scrubbed environment and reports whether the build was self-contained. The check SHALL run the
resulting executable and SHALL fail if the executable does not run successfully.

The build the check performs SHALL exercise the bundled C compiler on a translation unit whose stack
frame exceeds one page, so that the compiler-runtime symbols emitted for large frames are genuinely
demanded by the link the check verifies. The check SHALL additionally assert that the shipped
compiler-runtime shim defines each symbol on the declared required-symbol set, so that a shim
regenerated without one fails the check rather than waiting for a downstream project to discover it.

#### Scenario: Self-contained build passes

- **WHEN** the check runs against a correctly provisioned toolkit
- **THEN** the build SHALL succeed, the produced executable SHALL run, and the check SHALL report
  success

#### Scenario: Shim is missing a required compiler-runtime symbol

- **WHEN** the check runs against a toolkit whose compiler-runtime shim does not define one of the
  declared required symbols
- **THEN** the check SHALL fail
- **AND** the failure message SHALL name the missing symbol and the command that regenerates the shim

#### Scenario: Build leaks a host dependency

- **WHEN** the check runs and any linker input, compiler input, or executed tool resolves to a path
  outside the toolkit root
- **THEN** the check SHALL fail
- **AND** the failure message SHALL name each offending path and the toolkit file that should have
  supplied it instead

#### Scenario: Host toolchain variables are scrubbed

- **WHEN** the check runs in a shell where host MSVC and Windows SDK environment variables are set
- **THEN** the check SHALL remove them for the duration of the build
- **AND** the check SHALL restore the caller's environment before returning, including on failure

### Requirement: Cross-target checks succeed without a host Visual Studio install

The toolkit SHALL provide a check that builds the bundled embedded sample for
`thumbv7em-none-eabihf` under a scrubbed host MSVC / Windows SDK environment. The check SHALL
succeed on a machine with no Visual Studio and no Windows SDK, provided the Windows link-input
sysroot is present. The same host-link isolation SHALL apply to the other shipped cross-target
checks whenever those builds compile a host artifact.

#### Scenario: thumbv7em check passes on a bare machine

- **WHEN** the `thumbv7em` check runs against a correctly provisioned toolkit on a machine with no
  Visual Studio and no Windows SDK
- **THEN** the bundled embedded sample SHALL build for `thumbv7em-none-eabihf`
- **AND** the check SHALL report success

#### Scenario: Host toolchain variables are scrubbed during a cross-target check

- **WHEN** the `thumbv7em` check runs in a shell where host MSVC and Windows SDK environment
  variables are set
- **THEN** the check SHALL remove them for the duration of the build
- **AND** the check SHALL restore the caller's environment before returning, including on failure

#### Scenario: Missing sysroot fails the cross-target check with a link-input diagnosis

- **WHEN** the Windows link-input sysroot is removed and the `thumbv7em` check runs
- **THEN** the check SHALL fail before invoking `cargo`
- **AND** the failure SHALL name the missing link inputs and the regeneration command
- **AND** the failure SHALL NOT report a missing or unusable linker

### Requirement: Check diagnoses missing link inputs accurately

When a build fails because link inputs are missing, the check SHALL attribute the failure to the
missing inputs rather than to a missing linker, and SHALL confirm which linker was actually used.

#### Scenario: Sysroot deleted

- **WHEN** the Windows link-input sysroot is removed and the check runs
- **THEN** the check SHALL report that the link inputs are missing, name the regeneration command, and
  SHALL NOT report a missing or unusable linker

#### Scenario: Bundled linker reported

- **WHEN** the check completes, whether it passes or fails
- **THEN** it SHALL report the path of the linker executable the build used
- **AND** that path SHALL be inside the toolkit root

### Requirement: Self-containment is enforced at release time

Producing an offline release package SHALL run the self-containment check, and SHALL abort if the
check fails, so a package that depends on host tooling is never published.

#### Scenario: Release blocked by a failing check

- **WHEN** the offline release pipeline runs and the self-containment check fails
- **THEN** the pipeline SHALL abort before writing the release package
- **AND** the check's failure output SHALL be surfaced to the operator

#### Scenario: Verification of a produced package

- **WHEN** an operator verifies a produced offline package on a machine with no Visual Studio and no
  Windows SDK
- **THEN** installing the package and running the check SHALL succeed without network access

