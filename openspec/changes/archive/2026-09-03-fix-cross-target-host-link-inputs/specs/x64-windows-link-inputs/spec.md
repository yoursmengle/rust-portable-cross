## ADDED Requirements

### Requirement: Cross-target builds use the bundled Windows link inputs for host artifacts

Whenever a toolkit build script invokes cargo for a non-Windows target (`thumbv7em-none-eabihf`,
`armv7-unknown-linux-musleabihf`, or `aarch64-unknown-linux-musl`), any host
`x86_64-pc-windows-msvc` artifact that cargo still has to link — a build script, a proc-macro, or
any other host binary — SHALL be linked with the same bundled Windows link-input sysroot used for
an `x86_64-pc-windows-msvc` target build. The host link SHALL NOT depend on a host Visual Studio
installation, a host Windows SDK installation, or ambient `LIB` / `INCLUDE` values.

#### Scenario: thumbv7em sample with a host build script on a machine without Visual Studio

- **WHEN** the bundled embedded sample is built for `thumbv7em-none-eabihf` through the toolkit
  build script on a machine with no Visual Studio and no Windows SDK
- **THEN** the host build-script executable SHALL link successfully
- **AND** the `thumbv7em-none-eabihf` firmware build SHALL complete

#### Scenario: Host toolchain present during a cross-target build

- **WHEN** a toolkit cross-target build that compiles a host build script runs on a machine that
  has Visual Studio and the Windows SDK installed
- **THEN** the build SHALL succeed
- **AND** the host link SHALL still search the bundled sysroot ahead of any host library path

#### Scenario: Sysroot missing during a cross-target build

- **WHEN** a toolkit build for `thumbv7em-none-eabihf`, `armv7-unknown-linux-musleabihf`, or
  `aarch64-unknown-linux-musl` starts and the Windows link-input sysroot is absent or incomplete
- **THEN** the build SHALL fail before invoking `cargo`
- **AND** the error SHALL name the missing sysroot path and the command that regenerates it
- **AND** the error SHALL NOT instruct the user to install Visual Studio, the MSVC linker,
  `link.exe`, or the Windows SDK

#### Scenario: Host link failure names missing libraries, not a missing linker

- **WHEN** a cross-target toolkit build reaches the host link and the Windows import libraries are
  not on the linker search path
- **THEN** the failure SHALL be attributable to missing link inputs such as `kernel32.lib`
- **AND** the failure SHALL NOT instruct the user to install a different linker

## MODIFIED Requirements

### Requirement: Documentation states the actual host requirements

Product documentation SHALL describe the host prerequisites for `x86_64-pc-windows-msvc` builds
accurately, and SHALL NOT claim host independence that the shipped package does not deliver.
Documentation for the cross targets SHALL also state that host build scripts and proc-macros are
linked with the bundled Windows link inputs and need no Visual Studio or Windows SDK installation.

#### Scenario: Offline README describes x64 host requirements

- **WHEN** a reader consults the offline documentation for the `x86_64-pc-windows-msvc` target
- **THEN** the documentation SHALL state that no Visual Studio, MSVC linker, or Windows SDK
  installation is required
- **AND** it SHALL name the supported Windows versions on which the produced executables run

#### Scenario: Offline README describes cross-target host linking

- **WHEN** a reader consults the offline documentation for `thumbv7em-none-eabihf` or another
  shipped cross target
- **THEN** the documentation SHALL state that cargo still links host build scripts as
  `x86_64-pc-windows-msvc` binaries
- **AND** it SHALL state that those host links use the bundled Windows link inputs and need no
  Visual Studio or Windows SDK installation
