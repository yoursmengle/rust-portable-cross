## ADDED Requirements

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
