# delivered-release-verification Specification

## Purpose

Make the exact files delivered to customers, including the installed EXE payload, pass a deterministic offline release gate before the public installer manifest can change.

## Requirements

### Requirement: Staging reuse is verified

Every release build SHALL verify the staged product version, pinned tools, declared files, target payloads, and recorded digests before installer compilation. `-SkipStaging` SHALL skip only regeneration and SHALL perform the same read-only staging verification.

#### Scenario: Stale staging
- **WHEN** staging belongs to a different product version
- **THEN** the build fails before compiling or publishing an installer

#### Scenario: Damaged staged file
- **WHEN** a declared staged file is missing or has different bytes from its integrity index
- **THEN** the build identifies the damaged file and leaves the public manifest unchanged

### Requirement: The release build produces the installer without installing it

After ISCC reports success, the expected EXE SHALL exist, and the build SHALL then export and publish it. By default the release build SHALL NOT install the EXE or run builds against it: its checks are the read-only staging verification and the checks that staging preparation performs.

#### Scenario: Compiler omits output
- **WHEN** ISCC exits successfully without writing the expected EXE
- **THEN** the release build fails

#### Scenario: Default release build
- **WHEN** a release build runs without requesting installed-EXE validation
- **THEN** it produces, exports and publishes the EXE without installing it

### Requirement: Installed-EXE validation is available on request

When installed-EXE validation is requested, the release build SHALL install the compiled EXE into a disposable verification location. Its installed payload SHALL pass the integrity check and the offline smoke builds before export and split publication. Failure SHALL preserve the previous public manifest.

#### Scenario: Installer payload fails
- **WHEN** validation is requested and the installed EXE payload is incomplete or a smoke build fails
- **THEN** no new split manifest is published

### Requirement: Installed components work using only their own tools

The installed-EXE validation SHALL run the installation finalization and prove offline host, Linux cross-target, and embedded smoke builds using only the installation root's managed tools. The smoke fixtures SHALL require no external Cargo packages and SHALL exercise a host build script and proc macro, a Windows C build script, and bare-metal BIN/HEX generation.

#### Scenario: Source tools are unavailable
- **WHEN** the source checkout and system Rust are absent from the validation process PATH
- **THEN** the installed toolkit either completes all smoke builds with its own tools or the validation fails

#### Scenario: Required host tool is missing
- **WHEN** the installed `rust-objcopy`, Zig, or the pinned compiler is missing
- **THEN** the validation fails before the installer is published

### Requirement: Staging is never installed as a separate copy

The release build SHALL verify staging read-only and SHALL NOT run the installation and smoke builds on a separately assembled copy of staging. When installation is proven, it is proven on the compiled EXE.

#### Scenario: Validation requested
- **WHEN** a release build runs with installed-EXE validation requested
- **THEN** finalization and the smoke builds run exactly once, against the installed EXE

### Requirement: Disposable install location is short and under the build output

Installed-EXE validation SHALL place the disposable verification install under the build's output root, in a directory short enough for the installer's path-length budget, so that a single antivirus exclusion on the output root covers both staging and the disposable install. When the output root is too deep for that budget, the build SHALL fall back to the user's temporary directory and SHALL say so.

#### Scenario: Normal checkout depth
- **WHEN** installed-EXE validation runs from a checkout whose output root fits the path-length budget
- **THEN** the disposable install is created under the output root and removed after validation

#### Scenario: Checkout is too deep
- **WHEN** the output root exceeds the path-length budget
- **THEN** the build warns and installs under the temporary directory instead

### Requirement: Complete sample is an offline validation gate
Installed-EXE validation SHALL build the bundled full sample under an isolated Cargo environment with blocked process-level network access before the public installer manifest changes.

#### Scenario: Missing sample dependency
- **WHEN** an installed sample dependency is absent or corrupt
- **THEN** the validation fails and no new public installer manifest is published

#### Scenario: All supported targets
- **WHEN** the complete sample and embedded sample are built for the Windows host, ARMv7 Linux, AArch64 Linux, and Thumbv7EM targets
- **THEN** each build uses the installed toolchain and either succeeds or blocks publication with a diagnostic

### Requirement: Target artifact identity is a validation gate
After the installed smoke builds, installed-EXE validation SHALL inspect the generated Windows, ARMv7, AArch64, and Thumbv7EM artifacts before an installer or split manifest is published.

#### Scenario: Installed output has wrong architecture
- **WHEN** a build exits successfully but emits an artifact for an unexpected architecture
- **THEN** installed release validation fails and the public manifest stays unchanged
