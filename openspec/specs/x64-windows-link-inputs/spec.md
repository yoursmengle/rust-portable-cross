# x64-windows-link-inputs Specification

## Purpose
Guarantees that building for `x86_64-pc-windows-msvc` with this toolkit requires only files the
toolkit itself ships, by supplying the Windows import libraries and C-runtime shim that the bundled
`rust-lld` needs as link inputs.
## Requirements
### Requirement: Toolkit supplies its own Windows link inputs

The toolkit SHALL ship a Windows link-input sysroot for `x86_64-pc-windows-msvc` under its own root.
The sysroot SHALL provide, at minimum, import libraries for every library `rustc` names for a default
`std` binary — `kernel32`, `ntdll`, `userenv`, `ws2_32`, `dbghelp`, `advapi32`, `user32`, `ole32`,
`oleaut32`, `shell32`, `bcrypt` — and a C-runtime library satisfying `/defaultlib:msvcrt`.

#### Scenario: Sysroot present after installation

- **WHEN** the toolkit is installed from an offline package and no build has been run
- **THEN** the sysroot directory exists under the toolkit root
- **AND** it contains an import library file for each of the libraries named above
- **AND** it contains a library that resolves the default CRT reference emitted for the MSVC target

#### Scenario: Sysroot is missing

- **WHEN** a build for `x86_64-pc-windows-msvc` starts and the sysroot is absent or incomplete
- **THEN** the build SHALL fail before invoking `cargo`
- **AND** the error SHALL name the missing sysroot path and the command that regenerates it
- **AND** the error SHALL NOT instruct the user to install Visual Studio, the MSVC linker, `link.exe`,
  or the Windows SDK

### Requirement: Link inputs are regenerated offline from bundled assets

The toolkit SHALL provide a command that regenerates the entire Windows link-input sysroot using only
files already inside the toolkit root. Regeneration SHALL NOT require network access, a host Visual
Studio installation, a host Windows SDK installation, or any Microsoft-licensed binary.

#### Scenario: Regeneration on a clean machine

- **WHEN** the regeneration command runs on a machine with no Visual Studio, no Windows SDK, and no
  network connectivity
- **THEN** the command SHALL complete successfully
- **AND** the resulting sysroot SHALL be sufficient to link the bundled sample for
  `x86_64-pc-windows-msvc`

#### Scenario: Regeneration is reproducible

- **WHEN** the regeneration command runs twice against the same toolkit
- **THEN** the second run SHALL produce a sysroot whose file names and contents match the first run's

### Requirement: Redistributed link inputs carry no Microsoft-licensed payload

Every file the toolkit ships in the Windows link-input sysroot SHALL be derived from assets already
bundled with the toolkit under licences that permit redistribution. The toolkit SHALL NOT redistribute
Microsoft Visual C++ runtime libraries or Windows SDK libraries.

#### Scenario: Licence audit of shipped sysroot

- **WHEN** the shipped sysroot is audited against its provenance record
- **THEN** every file SHALL be traceable to a bundled source asset and its licence
- **AND** no file SHALL originate from a Visual Studio or Windows SDK installation directory

### Requirement: The build uses the bundled link inputs exclusively

When building for `x86_64-pc-windows-msvc`, the toolkit SHALL direct the linker's library search to
the bundled sysroot and SHALL suppress the compiler's discovery of host Visual Studio and Windows SDK
library paths.

#### Scenario: Host toolchain present but unused

- **WHEN** a build runs on a machine that has Visual Studio and the Windows SDK installed
- **THEN** the build SHALL succeed
- **AND** no library the linker resolved SHALL come from a path outside the toolkit root

#### Scenario: Host toolchain absent

- **WHEN** a build runs on a machine with no Visual Studio and no Windows SDK
- **THEN** the build SHALL succeed and produce an executable that runs on that machine

#### Scenario: Ambient MSVC environment is ignored

- **WHEN** a build runs in a shell where `LIB`, `INCLUDE`, `VCINSTALLDIR` or `WindowsSdkDir` are set to
  host locations
- **THEN** those values SHALL NOT influence which libraries the linker resolves

### Requirement: Offline packaging ships the link inputs

The offline release package and its install layout SHALL include the Windows link-input sysroot as
part of the component that is always installed, so that every installation is able to build for
`x86_64-pc-windows-msvc` without further downloads.

#### Scenario: Install layout lists the sysroot

- **WHEN** an offline release package is produced
- **THEN** the install layout manifest SHALL list every sysroot file under the always-installed
  component

#### Scenario: Fresh install builds for the Windows host target

- **WHEN** the offline package is installed on a machine with no Visual Studio and no Windows SDK, and
  only the default components are selected
- **THEN** building the bundled sample for `x86_64-pc-windows-msvc` SHALL succeed

### Requirement: Documentation states the actual host requirements

Product documentation SHALL describe the host prerequisites for `x86_64-pc-windows-msvc` builds
accurately, and SHALL NOT claim host independence that the shipped package does not deliver.

#### Scenario: Offline README describes x64 host requirements

- **WHEN** a reader consults the offline documentation for the `x86_64-pc-windows-msvc` target
- **THEN** the documentation SHALL state that no Visual Studio, MSVC linker, or Windows SDK
  installation is required
- **AND** it SHALL name the supported Windows versions on which the produced executables run

