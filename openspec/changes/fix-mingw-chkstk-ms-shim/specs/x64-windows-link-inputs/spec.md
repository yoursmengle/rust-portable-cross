## MODIFIED Requirements

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

## ADDED Requirements

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
