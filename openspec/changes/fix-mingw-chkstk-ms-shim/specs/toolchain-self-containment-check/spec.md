## MODIFIED Requirements

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
