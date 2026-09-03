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

The sysroot SHALL additionally supply every symbol the bundled C compiler emits a call to that
neither the C-runtime import library nor Rust's own compiler builtins define. Two classes fall under
this:

- Compiler-runtime symbols emitted implicitly by codegen. Because the bundled C compiler targets the
  GNU ABI while the final link runs in MSVC mode, this set SHALL include the stack probe under both
  the MSVC spelling and the MinGW spelling.
- C-runtime functions that the platform C runtime provides only as header inlines and therefore does
  not export from any DLL. This set SHALL include the narrow-character formatted input and output
  families, and each supplied function SHALL behave as the platform's own header inline does.

#### Scenario: Sysroot present after installation

- **WHEN** the toolkit is installed from an offline package and no build has been run
- **THEN** the sysroot directory exists under the toolkit root
- **AND** it contains an import library file for each of the libraries named above
- **AND** it contains a library that resolves the default CRT reference emitted for the MSVC target

#### Scenario: C code with a stack frame larger than one page

- **WHEN** a crate's build script compiles a C translation unit containing a function whose stack
  frame exceeds one page, and the resulting object is linked into an `x86_64-pc-windows-msvc` binary
- **THEN** the link SHALL succeed using only the bundled link inputs
- **AND** the produced executable SHALL run that function without corrupting the stack

#### Scenario: C code calling formatted input or output

- **WHEN** a crate's build script compiles C that calls `printf`, `fprintf`, `sprintf`, `snprintf` or
  `sscanf`, and the resulting object is linked into an `x86_64-pc-windows-msvc` binary
- **THEN** the link SHALL succeed using only the bundled link inputs
- **AND** the produced executable SHALL format and parse to the same results the platform C runtime
  produces, including the return value and null termination that each function is specified to give

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

### Requirement: Regeneration verifies the shim's required symbols

The command that regenerates the Windows link inputs SHALL verify that the produced compiler-runtime
shim defines every symbol on a declared required-symbol set, and SHALL fail loudly, naming the
missing symbols, when it does not. The required-symbol set SHALL be recorded alongside the generator
so that adding a symbol is a single declared edit rather than an implicit consequence of the shim's
source.

#### Scenario: Shim is missing a required symbol

- **WHEN** the regeneration command runs and the produced shim archive does not define one of the
  declared required symbols
- **THEN** the command SHALL fail
- **AND** the failure message SHALL name each missing symbol

#### Scenario: Shim defines every required symbol

- **WHEN** the regeneration command runs against a correctly provisioned toolkit
- **THEN** the verification SHALL pass and the sysroot SHALL be written

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

