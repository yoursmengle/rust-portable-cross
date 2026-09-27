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

### Requirement: Staged components work after installation assembly

Release preparation SHALL assemble the staged core and all target components under a separate installation root, run the existing installation finalization, and prove offline host, Linux cross-target, and embedded smoke builds using only that root's managed tools. The smoke fixtures SHALL require no external Cargo packages and SHALL exercise a host build script and proc macro, a Windows C build script, and bare-metal BIN/HEX generation.

#### Scenario: Source tools are unavailable
- **WHEN** the source checkout and system Rust are absent from the validation process PATH
- **THEN** the assembled install either completes all smoke builds with its own tools or release preparation fails

#### Scenario: Required host tool is missing
- **WHEN** staged `rust-objcopy`, Zig, or the pinned compiler is missing
- **THEN** release preparation fails before the installer is published

### Requirement: The actual installer is a publication gate

After ISCC reports success, the expected EXE SHALL exist and SHALL be installed into a disposable verification location. Its installed payload SHALL pass the same integrity and offline smoke checks before export and split publication. Failure SHALL preserve the previous public manifest.

#### Scenario: Compiler omits output
- **WHEN** ISCC exits successfully without writing the expected EXE
- **THEN** the release build fails

#### Scenario: Installer payload fails
- **WHEN** the installed EXE payload is incomplete or a smoke build fails
- **THEN** no new split manifest is published
