# toolkit-path-portability Specification

## Purpose

Keep the existing portable Rust toolkit commands usable when Windows installation, project, and temporary paths contain Unicode, spaces, or shell metacharacters, and after the toolkit is moved to a new directory.

## Requirements

### Requirement: Build arguments retain path boundaries
The existing host and cross-build commands SHALL pass each managed linker, compiler, archive, and response-file argument as intended when the toolkit root, project root, or temporary root contains spaces, Unicode, `&`, or parentheses.

#### Scenario: Windows host linking under a complex path
- **WHEN** a Windows host build uses a bundled import-library directory whose path contains spaces and non-ASCII characters
- **THEN** the linker receives the complete `/LIBPATH` value as one argument and the build succeeds without a system SDK

#### Scenario: Cross build with a host build script
- **WHEN** a supported cross-target build compiles a host build script under a complex path
- **THEN** its host link uses the bundled Windows inputs while target-specific flags retain their original meaning

#### Scenario: Native wrapper arguments
- **WHEN** a native wrapper receives quoted paths, empty arguments, output options, or response files
- **THEN** it forwards the intended argument values to the bundled tool without truncation or encoding loss

### Requirement: Relocated toolkit resolves its current root
Generated wrappers and activation SHALL use the current installation root, and repeated activation SHALL not keep appending duplicate toolkit entries to PATH.

#### Scenario: Toolkit moved between directories
- **WHEN** an installed toolkit is moved and activated at the new location
- **THEN** its wrappers and tools use the new location and do not resolve executable assets from the old location

#### Scenario: Repeated activation
- **WHEN** the same toolkit is activated more than once in a PowerShell session
- **THEN** each managed PATH entry appears once

### Requirement: Release paths work in both supported PowerShell versions
The existing release preparation command SHALL compute paths relative to its staging roots on Windows PowerShell 5.1 and PowerShell 7, including Unicode and space-containing paths.

#### Scenario: Relative path under a complex directory
- **WHEN** staging runs under a directory containing spaces or Unicode
- **THEN** the generated internal file entries use the correct relative paths

#### Scenario: Paths on different volumes
- **WHEN** a relative-path operation receives paths on different volumes
- **THEN** it returns a usable absolute destination path instead of failing because of the PowerShell runtime
