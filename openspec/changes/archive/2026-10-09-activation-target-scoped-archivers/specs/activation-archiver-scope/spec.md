## Purpose

Ensures the interactive activation environment provides the bundled GNU-style archivers only to the cross targets that need them, so that `cargo` run directly in an activated shell can still build host crates that compile C sources.

## ADDED Requirements

### Requirement: Activation scopes bundled archivers to cross targets

When the bundled `zig-ar.cmd` / `zig-ranlib.cmd` wrappers are present, activation SHALL set the target-scoped archiver variables for `armv7-unknown-linux-musleabihf` and `aarch64-unknown-linux-musl`. These are `AR_<triple>` and `RANLIB_<triple>`, each in both the underscore and the hyphen spelling of the triple. Activation SHALL NOT set the unsuffixed `AR` or `RANLIB` variables. Activation SHALL NOT point any host-target (`x86_64-pc-windows-msvc`) archiver variable at a GNU-style archiver.

#### Scenario: Fresh activation

- **WHEN** a shell with no `AR` / `RANLIB` variables loads the activation script against a provisioned toolkit
- **THEN** `AR` and `RANLIB` SHALL remain unset
- **AND** the four `AR_*` and four `RANLIB_*` variables for the armv7 and aarch64 triples SHALL be set to `zig-ar.cmd` and `zig-ranlib.cmd` respectively

#### Scenario: Host crate with C sources builds after activation

- **WHEN** `cargo build` is run for the host target in an activated shell, on a crate whose dependency graph compiles a C static library through cc-rs
- **THEN** the archive step SHALL NOT be routed to the GNU-style `zig-ar` wrapper, and the build SHALL NOT fail with an archiver option error

### Requirement: Activation removes leftover toolkit archiver variables

On activation, if `AR` equals `zig-ar.cmd`, activation SHALL remove it. If `RANLIB` equals `zig-ranlib.cmd`, activation SHALL remove it. These are the values an earlier activation of this toolkit, or of an older toolkit version, set.

#### Scenario: Leftover from an earlier activation

- **WHEN** `AR=zig-ar.cmd` and `RANLIB=zig-ranlib.cmd` are set before activation
- **THEN** after activation both `AR` and `RANLIB` SHALL be unset

### Requirement: Activation preserves user-set archiver variables with a warning

On activation, if `AR` or `RANLIB` holds any value other than the toolkit's own leftover value, activation SHALL keep it unchanged. Activation SHALL also emit a warning that names the variable and explains that cc-rs uses it as the archiver for every target, including the host.

#### Scenario: User-set archiver is preserved

- **WHEN** `AR=custom.exe` is set before activation
- **THEN** after activation `AR` SHALL still equal `custom.exe`
- **AND** activation SHALL emit a warning naming `AR`

#### Scenario: Repeated activation is stable

- **WHEN** the activation script is loaded twice in the same shell
- **THEN** the archiver variables after the second load SHALL be identical to those after the first load, and no warning about `AR` / `RANLIB` SHALL be emitted
